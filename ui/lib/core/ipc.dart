// 核心进程桥:界面拉起 egland -ipc,经 stdin/stdout 一行一个 JSON 通信。
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
  int _nextId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  String _lastStderr = '';

  /// 全部入站消息(应答与事件),状态机只认这条流。
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  bool get running => _p != null;
  StreamSubscription<String>? _pRxSub;
  bool _exited = false;

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
    final p = await Process.start(exePath, ['-ipc']);
    _p = p;
    _exited = false;
    _lastStderr = '';
    _pRxSub = p.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onExit, onError: (_) => _onExit());
    p.stderr.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) {
      if (l.trim().isNotEmpty) _lastStderr = l.trim();
    }, onDone: _onExit);
    unawaited(p.exitCode.then((_) => _onExit()));
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

  void _onExit() {
    if (_exited) return;
    _exited = true;
    final err = IpcError(_lastStderr.isEmpty ? '核心进程已退出' : _lastStderr);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
    _p = null;
    _pRxSub?.cancel();
    _pRxSub = null;
    if (!_messages.isClosed) {
      _messages.add({'type': 'core-exit', 'message': err.message});
    }
  }

  // 发送请求并等首条应答;超时兜底,避免界面挂死。
  Future<Map<String, dynamic>> request(Map<String, dynamic> fields, {Duration timeout = const Duration(seconds: 10)}) {
    final p = _p;
    if (p == null) return Future.error(IpcError('核心进程未运行'));
    final id = 'r${_nextId++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final line = jsonEncode({...fields, 'id': id});
    try {
      p.stdin.writeln(line);
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
    final p = _p;
    if (p == null) return;
    _p = null;
    _exited = true; // 主动关闭不算崩溃,抑制 core-exit 事件
    try {
      await p.stdin.close(); // 界面关闭管道即视为退出指令,核心自行打扫
    } catch (_) {}
    try {
      p.kill();
    } catch (_) {}
    _pRxSub?.cancel();
    _pRxSub = null;
  }

  Future<void> dispose() => stop();
}
