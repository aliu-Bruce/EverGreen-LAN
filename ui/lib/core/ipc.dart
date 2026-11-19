// 核心进程桥:界面以普通权限拉起 egland -ipc,经 stdin/stdout 一行一个 JSON 通信。
// 需要管理员时,旧核心用 runas 拉起新核心,新核心经本机回环 TCP 连回界面;
// 界面用同一套行协议接管连接,自身始终不进入管理员权限。
// 每条请求带自增 id;应答按 id 关联,事件与全部消息同时进 messages 流
// 供状态机分流(join 的失败回报晚于 ack,只能从消息流辨认)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class IpcError implements Exception {
  final String message;
  IpcError(this.message);
  @override
  String toString() => message;
}

class IpcBridge {
  Process? _p;
  Socket? _s;
  IOSink? _in;
  int _gen = 0;
  int _nextId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  String _lastStderr = '';

  /// 全部入站消息(应答与事件),状态机只认这条流。
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  bool get running => _in != null && !_exited;
  StreamSubscription<String>? _rxSub;
  bool _exited = true;

  // 探测核心程序:界面同目录、当前目录,或任一上级的 dist 目录。
  static Future<String?> probe() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$exeDir\\egland.exe',
      '$cwd\\egland.exe',
      '$cwd\\dist\\egland.exe',
    ];
    var dir = Directory(exeDir);
    for (var i = 0; i < 8 && dir.parent.path != dir.path; i++) {
      dir = dir.parent;
      candidates.add('${dir.path}\\dist\\egland.exe');
    }
    for (final path in candidates) {
      final f = File(path);
      if (await f.exists()) return path;
    }
    return null;
  }

  Future<void> start(String exePath) async {
    await stop();
    final gen = ++_gen;
    final p = await Process.start(exePath, ['-ipc']);
    _p = p;
    _attach(p.stdout, p.stdin, gen);
    p.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) {
      if (gen == _gen && l.trim().isNotEmpty) _lastStderr = l.trim();
    }, onDone: () {}, onError: (_) {});
    unawaited(p.exitCode.then((_) => _onExit(gen)));
  }

  /// 接管提权核心的回环连接。首行必须是带令牌的认证消息;
  /// 认证通过前不开放请求入口,避免本机其它进程抢先接管。
  Future<void> adoptSocket(Socket socket, String token) async {
    await stop();
    final gen = ++_gen;
    _s = socket;
    _in = socket;
    _exited = false;
    _lastStderr = '';
    final lines = socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    final authed = Completer<void>();
    var ok = false;
    _rxSub = lines.listen((line) {
      if (!ok) {
        ok = true;
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          if (!authed.isCompleted) authed.completeError(IpcError('核心认证消息无效'));
          _onExit(gen);
          return;
        }
        if (msg['type'] != 'auth' || msg['token'] != token) {
          if (!authed.isCompleted) authed.completeError(IpcError('核心认证失败'));
          _onExit(gen);
          return;
        }
        if (!authed.isCompleted) authed.complete();
        return;
      }
      if (gen == _gen) _onLine(line);
    }, onDone: () => _onExit(gen), onError: (_) => _onExit(gen));
    try {
      await authed.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      _onExit(gen);
      rethrow;
    }
  }

  // 管道传输:核心的 stdout 逐行进,stdin 逐行出。
  void _attach(Stream<List<int>> rx, IOSink tx, int gen) {
    _in = tx;
    _exited = false;
    _lastStderr = '';
    _rxSub = rx
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (gen == _gen) _onLine(line);
    }, onDone: () => _onExit(gen), onError: (_) => _onExit(gen));
  }

  void _onLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = (msg['id'] as String?) ?? '';
    final type = (msg['type'] as String?) ?? '';
    final c = id.isNotEmpty ? _pending.remove(id) : null;
    if (c != null && !c.isCompleted) {
      if (type == 'err') {
        c.completeError(IpcError((msg['message'] as String?) ?? '未知错误'));
      } else {
        c.complete(msg);
      }
    }
    if (!_messages.isClosed) _messages.add(msg);
  }

  // gen 不符说明是上一代传输的迟到回调,直接忽略。
  void _onExit(int gen) {
    if (gen != _gen || _exited) return;
    _exited = true;
    final err = IpcError(_lastStderr.isEmpty ? '核心进程已退出' : _lastStderr);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
    _p = null;
    _s = null;
    _in = null;
    _rxSub?.cancel();
    _rxSub = null;
    if (!_messages.isClosed) {
      _messages.add({'type': 'core-exit', 'message': err.message});
    }
  }

  // 发送请求并等首条应答;超时兜底,避免界面挂死。
  Future<Map<String, dynamic>> request(Map<String, dynamic> fields, {Duration timeout = const Duration(seconds: 10)}) {
    final sink = _in;
    if (sink == null || _exited) return Future.error(IpcError('核心进程未运行'));
    final id = 'r${_nextId++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final line = jsonEncode({...fields, 'id': id});
    try {
      sink.writeln(line);
    } catch (e) {
      _pending.remove(id);
      return Future.error(IpcError('向核心写入失败: $e'));
    }
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw IpcError('核心没有应答(超时)');
    });
  }

  Future<void> stop() async {
    _gen++; // 旧传输的异步回调全部失效
    final p = _p;
    final s = _s;
    final sub = _rxSub;
    _p = null;
    _s = null;
    _in = null;
    _rxSub = null;
    _exited = true;
    await sub?.cancel();
    if (p != null) {
      try {
        await p.stdin.close(); // 界面关闭管道即视为退出指令,核心自行打扫
      } catch (_) {}
      try {
        p.kill();
      } catch (_) {}
    }
    if (s != null) {
      try {
        s.destroy();
      } catch (_) {}
    }
    final err = IpcError('核心进程已退出');
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
  }

  Future<void> dispose() => stop();
}
