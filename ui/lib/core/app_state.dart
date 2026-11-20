// 应用状态机:偏好、语言、核心桥与房间状态集中于此,ChangeNotifier 通知界面。
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../i18n.dart';
import 'appearance.dart';
import 'ipc.dart';
import 'prefs.dart';

enum RoomState { idle, hosting, joining, joined }

// 连接过程终端的一行;kind 决定配色与是否带跳动的进度点。
enum LogKind { ok, run, err }
class JoinLine {
  final LogKind kind;
  final String text;
  JoinLine(this.kind, this.text);
}

// 一条文件传输的界面状态:报价 → 进行中 → 完成/失败。
enum TransferPhase { offer, active, done, failed }

class TransferTask {
  final String id;
  final String peer; // 对端隧道 IP
  final String name; // 文件名(仅展示)
  final int size;
  final bool incoming;
  int done;
  TransferPhase phase;
  bool ok;
  String? error;
  String? path;

  TransferTask({
    required this.id,
    required this.peer,
    required this.name,
    required this.size,
    required this.incoming,
    this.done = 0,
    this.phase = TransferPhase.active,
    this.ok = false,
    this.error,
    this.path,
  });

  bool get finished => phase == TransferPhase.done || phase == TransferPhase.failed;
  bool get awaiting => phase == TransferPhase.offer;
  double get progress => size <= 0 ? 0 : (done / size).clamp(0.0, 1.0);
}

class AppState extends ChangeNotifier {
  final Prefs prefs = Prefs();
  final EgLangs langs = EgLangs();
  final IpcBridge bridge = IpcBridge();

  // 外观参数(主色/字体/字号/圆角),直接由设置页控件编辑。
  AppAppearance appearance = const AppAppearance();
  bool bridgeReady = false;
  String? bridgeProblem;

  // 运行权限:核心报告的是否已提权、能否一键提权。
  bool? admin;
  bool canElevate = false;
  bool _elevating = false;
  String? _corePath;

  bool get elevating => _elevating;

  RoomState room = RoomState.idle;
  String? code;      // 房间码展示形态 XXXX XXXX
  String? selfIp;    // 本机虚拟地址
  String? hostName;  // 房主机显示名(成员侧)
  List<Map<String, dynamic>> members = [];

  // 文件传输:本房间内的待接收报价、进行中与最近记录。
  List<TransferTask> transfers = [];

  // 公网直连:开房后核心给出局域网地址;探测给出 NAT 映射地址。
  List<String> lanAddrs = [];
  String? publicAddr; // ip:port
  bool stunRunning = false;
  String? stunError;
  int _stunSeq = 0;

  // 局域网发现:核心在空闲时推送的房间快照与发现加入的失败原因。
  List<Map<String, dynamic>> discovered = [];
  String? discoverError;
  String? joiningCode; // 正在尝试加入的发现房间码,用于只标记那一张卡
  bool _joinFromDiscovery = false;

  List<JoinLine> joinLog = [];
  String? joinError; // errterm 标题行(核心原文)

  String _lastJoinId = '';
  String _lastHostId = '';
  bool _joinPending = false; // 请求已发出、首应答未回:挡住重复点击
  StreamSubscription<Map<String, dynamic>>? _sub;

  // ---- 启动 ----
  Future<void> init() async {
    prefs.loadSync();
    appearance = AppAppearance.fromMap(prefs.appearance);
    await langs.load();
    final saved = prefs.lang;
    langs.set(saved.isNotEmpty ? saved : EgLangs.detectSystem());
    if (prefs.name.isEmpty) {
      prefs.name = egDefaultName(Platform.environment['USERNAME']);
      unawaited(prefs.save());
    }
    final path = await IpcBridge.probe();
    if (path == null) {
      bridgeProblem = langs.t('err.bridgeMissing');
      notifyListeners();
      return;
    }
    try {
      _corePath = path;
      await bridge.start(path);
      bridgeReady = true;
      _sub = bridge.messages.listen(_onMessage, onError: (Object e) {
        bridgeProblem = e.toString();
        bridgeReady = false;
        _setRoom(RoomState.idle);
        notifyListeners();
      });
      _requestInitial();
    } catch (e) {
      bridgeProblem = e.toString();
    }
    notifyListeners();
  }

  // 首帧之后补拉一次状态与权限;失败不阻塞界面。
  void _requestInitial() {
    unawaited(bridge.request({'op': 'status'}, timeout: const Duration(seconds: 3)).catchError((_) => <String, dynamic>{}));
    unawaited(bridge.request({'op': 'env'}, timeout: const Duration(seconds: 3)).catchError((_) => <String, dynamic>{}));
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(bridge.dispose());
    super.dispose();
  }

  // ---- 语言与外观 ----
  void setLang(String code) {
    langs.set(code);
    prefs.lang = code;
    unawaited(prefs.save());
    notifyListeners();
  }

  void setThemeMode(EgThemeMode mode) {
    prefs.themeMode = mode;
    unawaited(prefs.save());
    notifyListeners();
  }

  void setNavMode(EgNavMode mode) {
    prefs.navMode = mode;
    unawaited(prefs.save());
    notifyListeners();
  }

  // 外观即时生效并持久化;没有主题选择/导入概念。
  void setAppearance(AppAppearance value) {
    appearance = value;
    prefs.appearance = value.toJson();
    unawaited(prefs.save());
    notifyListeners();
  }

  void resetAppearance() => setAppearance(const AppAppearance());

  void setName(String name) {
    final n = name.trim();
    if (n.isEmpty || n == prefs.name) return;
    prefs.name = n;
    unawaited(prefs.save());
    notifyListeners();
  }

  void setNet(int port, int mtu) {
    prefs.port = port;
    prefs.mtu = mtu;
    unawaited(prefs.save());
    notifyListeners();
  }

  // STUN 只影响下一次显式探测;换服务器后旧的公网地址不再可信。
  void setStun(String server) {
    final s = server.trim();
    if (s == prefs.stun) return;
    prefs.stun = s;
    publicAddr = null;
    stunError = null;
    _stunSeq++;
    stunRunning = false;
    unawaited(prefs.save());
    notifyListeners();
  }

  // 设置页试连:用独立套接字探测一次,不影响房间状态,也不改动偏好。
  // 成功返回规范化后的服务器与公网映射地址;失败抛出 IpcError。
  Future<({String server, String addr})> testStun(String server) async {
    if (!bridgeReady) throw IpcError(langs.t('err.coreNotRunning'));
    final ack = await bridge.request({
      'op': 'test-stun',
      'server': server,
    }, timeout: const Duration(seconds: 12));
    final ip = (ack['ip'] as String?)?.trim() ?? '';
    final port = (ack['port'] as num?)?.toInt() ?? 0;
    final normalized = (ack['server'] as String?)?.trim() ?? server.trim();
    if (ip.isEmpty || port <= 0) throw IpcError(langs.t('err.stunReply'));
    return (server: normalized, addr: '$ip:$port');
  }

  // 从房间套接字探测 NAT 映射;只有开房后核心才有可探测的套接字。
  Future<void> probePublic() async {
    if (room != RoomState.hosting || stunRunning) return;
    final seq = ++_stunSeq;
    stunRunning = true;
    stunError = null;
    notifyListeners();
    String? error;
    try {
      final ack = await bridge.request({
        'op': 'stun',
        'server': prefs.stun,
      }, timeout: const Duration(seconds: 8));
      final ip = (ack['ip'] as String?)?.trim() ?? '';
      final port = (ack['port'] as num?)?.toInt() ?? 0;
      if (ip.isEmpty || port <= 0) {
        error = langs.t('err.stunReply');
      } else if (seq == _stunSeq && room == RoomState.hosting) {
        publicAddr = '$ip:$port';
      }
    } on IpcError catch (e) {
      error = e.message;
    } finally {
      if (seq == _stunSeq) {
        stunRunning = false;
        stunError = error;
        notifyListeners();
      }
    }
  }

  void finishOnboarding() {
    prefs.onboarded = true;
    unawaited(prefs.save());
    notifyListeners();
  }

  // 只重启后台核心:界面监听本机回环端口,旧核心用 runas 拉起新核心,
  // 新核心连回后由界面接管;界面自身始终是普通权限。成功返回 null。
  Future<String?> elevateCore() async {
    if (_elevating) return null;
    if (!bridgeReady) return langs.t('err.coreNotRunning');
    if (admin == true) return null;
    final path = _corePath;
    if (path == null) return langs.t('err.bridgeMissing');
    _elevating = true;
    notifyListeners();

    ServerSocket? server;
    Socket? socket;
    try {
      final token = _randomToken();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final ack = await bridge.request({
        'op': 'elevate-core',
        'addr': '127.0.0.1:${server.port}',
        'token': token,
      }, timeout: const Duration(minutes: 10)); // UAC 提示可能停留很久
      if (ack['relaunched'] != true) return null; // 已是管理员
      await bridge.stop(); // 旧核心已交棒,主动断开并抑制它的退出事件
      bridgeReady = false;
      notifyListeners();

      socket = await server.first.timeout(const Duration(seconds: 60));
      await bridge.adoptSocket(socket, token);
      socket = null; // 连接已交给桥,后续由桥管理
      bridgeReady = true;
      bridgeProblem = null;
      admin = true;
      canElevate = true;
      notifyListeners();

      final env = await bridge.request({'op': 'env'}, timeout: const Duration(seconds: 5));
      admin = env['admin'] == true;
      canElevate = env['canElevate'] == true;
      unawaited(bridge.request({'op': 'status'}, timeout: const Duration(seconds: 3)).catchError((_) => <String, dynamic>{}));
      return null;
    } on TimeoutException {
      await _restoreCore(path);
      return langs.t('err.elevateTimeout');
    } on IpcError catch (e) {
      await _restoreCore(path);
      return e.message;
    } catch (e) {
      await _restoreCore(path);
      return e.toString();
    } finally {
      _elevating = false;
      try {
        await server?.close();
      } catch (_) {}
      socket?.destroy();
      notifyListeners();
    }
  }

  // 提权失败时恢复普通核心;UAC 取消时旧核心仍在,直接沿用。
  Future<void> _restoreCore(String path) async {
    if (bridge.running) {
      bridgeReady = true;
      return;
    }
    try {
      await bridge.start(path);
      _corePath = path;
      bridgeReady = true;
      bridgeProblem = null;
      _requestInitial();
    } catch (e) {
      bridgeReady = false;
      bridgeProblem = e.toString();
      _setRoom(RoomState.idle);
    }
  }

  // 32 位十六进制令牌;核心在回环连接首行报出,界面据此确认对端身份。
  String _randomToken() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- 房间操作 ----
  // 开房间;返回 null 表示已进入 hosting,非 null 为错误原文(需要管理员等)。
  Future<String?> createRoom() async {
    if (room != RoomState.idle) return null;
    discoverError = null;
    _lastHostId = '';
    try {
      final ack = await bridge.request({
        'op': 'start-host',
        'name': prefs.name,
        'listen': prefs.port,
        'mtu': prefs.mtu,
      }, timeout: const Duration(seconds: 30));
      _applyRoomFields(ack);
      notifyListeners();
      return null;
    } on IpcError catch (e) {
      return e.message;
    }
  }

  // 入房;ack 后由 room-up 事件推进到 joined,失败回报走 err(带同一 id)。
  // fromDiscovery 为真时失败原因走 discoverError,留在主页内联提示。
  Future<void> joinRoom(String displayCode, String peer, {bool fromDiscovery = false}) async {
    if (room != RoomState.idle || _joinPending) return;
    _joinPending = true;
    discoverError = null;
    _joinFromDiscovery = fromDiscovery;
    joiningCode = fromDiscovery ? _normalized(displayCode) : null;
    if (!fromDiscovery) joinError = null;
    joinLog = [];
    notifyListeners();
    final codeDisp = _displayOf(displayCode);
    joinLog = [JoinLine(LogKind.ok, langs.t('log.resolve', {'code': codeDisp}))];
    notifyListeners();
    try {
      final ack = await bridge.request({
        'op': 'join',
        'code': displayCode,
        'peer': _peerWithPort(peer),
        'name': prefs.name,
        'mtu': prefs.mtu,
      }, timeout: const Duration(seconds: 25));
      // ack(state=joining)只回执;真正的失败与成功都来自后续消息流。
      _lastJoinId = (ack['id'] as String?) ?? '';
      joinLog = [
        ...joinLog,
        JoinLine(LogKind.ok, langs.t('log.dial', {'peer': _peerWithPort(peer)})),
        JoinLine(LogKind.run, langs.t('log.tunnel')),
      ];
      _joinPending = false;
      room = RoomState.joining;
      notifyListeners();
    } on IpcError catch (e) {
      _joinPending = false;
      _joinFromDiscovery = false;
      joiningCode = null;
      if (fromDiscovery) {
        discoverError = e.message;
      } else {
        joinError = e.message;
        joinLog = [...joinLog, JoinLine(LogKind.err, e.message)];
      }
      room = RoomState.idle;
      notifyListeners();
    }
  }

  Future<void> leaveRoom() async {
    if (room == RoomState.idle) return;
    try {
      await bridge.request({'op': 'stop'}, timeout: const Duration(seconds: 10));
    } on IpcError catch (_) {
      // stop 幂等;失败也按已离开处理,界面回主页。
    }
    discoverError = null;
    _setRoom(RoomState.idle);
    notifyListeners();
  }

  Future<void> refreshMembers() async {
    if (room != RoomState.hosting && room != RoomState.joined) return;
    try {
      await bridge.request({'op': 'members'}, timeout: const Duration(seconds: 5));
    } on IpcError catch (_) {}
  }

  // ---- 文件传输 ----
  // 系统原生对话框;取消返回 null。超时给足,用户可能慢慢找文件。
  Future<String?> pickFile({String? title}) async {
    final ack = await bridge.request({
      'op': 'pick-file',
      'title': title ?? langs.t('tr.pickTitle'),
    }, timeout: const Duration(minutes: 5));
    if (ack['cancel'] == true) return null;
    final path = (ack['path'] as String?) ?? '';
    return path.isEmpty ? null : path;
  }

  Future<String?> pickSave(String suggestedName) async {
    final ack = await bridge.request({
      'op': 'pick-save',
      'title': langs.t('tr.saveTitle'),
      'name': suggestedName,
    }, timeout: const Duration(minutes: 5));
    if (ack['cancel'] == true) return null;
    final path = (ack['path'] as String?) ?? '';
    return path.isEmpty ? null : path;
  }

  // 发送文件;返回错误原文,null 表示已交给核心。
  Future<String?> sendFile(String path, {String? to}) async {
    if (!inRoom) return '尚未进入房间';
    var size = 0;
    try {
      size = await File(path).length();
    } catch (_) {}
    try {
      final ack = await bridge.request({
        'op': 'send-file',
        'path': path,
        if (to != null && to.isNotEmpty) 'to': to,
      }, timeout: const Duration(seconds: 15));
      final id = (ack['transfer'] as String?) ?? '';
      if (id.isEmpty) return '核心没有返回传输编号';
      _addTransfer(TransferTask(
        id: id,
        peer: to ?? (room == RoomState.joined ? hostAddr : ''),
        name: _baseName(path),
        size: size,
        incoming: false,
      ));
      notifyListeners();
      return null;
    } on IpcError catch (e) {
      return e.message;
    }
  }

  // 接受报价:先弹保存对话框,再回核心。取消不算错误。
  Future<String?> acceptTransfer(TransferTask t) async {
    String? path;
    try {
      path = await pickSave(t.name);
    } on IpcError catch (e) {
      return e.message;
    }
    if (path == null) return null;
    try {
      await bridge.request({
        'op': 'accept-file',
        'transfer': t.id,
        'path': path,
      }, timeout: const Duration(seconds: 10));
      t.phase = TransferPhase.active;
      t.path = path;
      notifyListeners();
      return null;
    } on IpcError catch (e) {
      return e.message;
    }
  }

  Future<String?> rejectTransfer(TransferTask t) async {
    try {
      await bridge.request({
        'op': 'reject-file',
        'transfer': t.id,
      }, timeout: const Duration(seconds: 10));
      transfers.remove(t);
      notifyListeners();
      return null;
    } on IpcError catch (e) {
      return e.message;
    }
  }

  void clearFinishedTransfers() {
    transfers.removeWhere((t) => t.finished);
    notifyListeners();
  }

  // 对端显示名:主机看成员名册,成员看房主名;找不到时退回 IP。
  String peerLabel(String ip) {
    if (ip.isEmpty) return '—';
    if (ip == selfIp) return prefs.name;
    if (room == RoomState.joined && ip == hostAddr) return hostName ?? ip;
    for (final m in members) {
      if ((m['ip'] as String?) == ip) return (m['name'] as String?) ?? ip;
    }
    return ip;
  }

  TransferTask? _transferOf(String id) {
    for (final t in transfers) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _addTransfer(TransferTask t) {
    transfers.insert(0, t);
    // 记录上限:优先淘汰最旧的已结束项,不动进行中的传输。
    if (transfers.length > 60) {
      for (var i = transfers.length - 1; i >= 0 && transfers.length > 60; i--) {
        if (transfers[i].finished) transfers.removeAt(i);
      }
    }
  }

  // 事件可能先于发送应答到达(接收方已在等),缺任务时按事件字段补建。
  TransferTask _adoptTransfer(String id, Map<String, dynamic> msg) {
    final t = TransferTask(
      id: id,
      peer: (msg['peer'] as String?) ?? '',
      name: (msg['file'] as String?) ?? '',
      size: (msg['size'] as num?)?.toInt() ?? 0,
      incoming: msg['incoming'] == true,
    );
    _addTransfer(t);
    return t;
  }

  void _applyTransferEvent(String name, Map<String, dynamic> msg) {
    if (!inRoom) return; // 离房后迟到的进度事件不再进列表
    final id = (msg['transfer'] as String?) ?? '';
    if (id.isEmpty) return;
    switch (name) {
      case 'file-offer':
        if (_transferOf(id) == null) {
          _addTransfer(TransferTask(
            id: id,
            peer: (msg['peer'] as String?) ?? '',
            name: (msg['file'] as String?) ?? '',
            size: (msg['size'] as num?)?.toInt() ?? 0,
            incoming: true,
            phase: TransferPhase.offer,
          ));
        }
      case 'file-progress':
        final t = _transferOf(id) ?? _adoptTransfer(id, msg);
        t.done = (msg['done'] as num?)?.toInt() ?? t.done;
        if (t.phase == TransferPhase.offer) t.phase = TransferPhase.active;
      case 'file-done':
        final t = _transferOf(id) ?? _adoptTransfer(id, msg);
        t.done = (msg['done'] as num?)?.toInt() ?? t.size;
        t.ok = msg['ok'] == true;
        final err = (msg['error'] as String?) ?? '';
        t.error = err.isEmpty ? null : err;
        final path = (msg['path'] as String?) ?? '';
        if (path.isNotEmpty) t.path = path;
        t.phase = t.ok ? TransferPhase.done : TransferPhase.failed;
    }
  }

  String _baseName(String path) {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  // ---- IPC 消息分流 ----
  void _onMessage(Map<String, dynamic> msg) {
    final type = (msg['type'] as String?) ?? '';
    final id = (msg['id'] as String?) ?? '';
    switch (type) {
      case 'ok':
        final state = (msg['state'] as String?) ?? '';
        if (state == 'idle') {
          _setRoom(RoomState.idle);
        } else {
          _applyRoomFields(msg);
        }
      case 'err':
        if (id.isNotEmpty && id == _lastJoinId) {
          final message = (msg['message'] as String?) ?? '加入失败';
          if (_joinFromDiscovery) {
            discoverError = message;
          } else {
            joinError = message;
            joinLog = [...joinLog.where((l) => l.kind != LogKind.run), JoinLine(LogKind.err, message)];
          }
          _joinFromDiscovery = false;
          joiningCode = null;
          room = RoomState.idle;
          _lastJoinId = '';
        } else if (id.isNotEmpty && id == _lastHostId) {
          // 开房失败错误已由 createRoom 的首应答路径给出,这里只兜底
          room = RoomState.idle;
        }
      case 'status':
        final state = (msg['state'] as String?) ?? 'idle';
        _setRoom(RoomState.values.firstWhere((r) => r.name == state, orElse: () => RoomState.idle));
        _applyRoomFields(msg);
      case 'members':
        members = ((msg['list'] as List<dynamic>?) ?? []).cast<Map<String, dynamic>>();
        notifyListeners();
      case 'event':
        final name = (msg['name'] as String?) ?? '';
        if (name == 'room-up') {
          _applyRoomFields(msg);
          room = RoomState.joined;
          _lastJoinId = '';
          _joinFromDiscovery = false;
          joiningCode = null;
          discoverError = null;
          joinLog = [
            ...joinLog.where((l) => l.kind != LogKind.run && l.kind != LogKind.err),
            JoinLine(LogKind.ok, langs.t('log.joined', {'ip': selfIp ?? '—'})),
          ];
        } else if (name == 'room-down') {
          final message = (msg['message'] as String?) ?? '';
          _setRoom(RoomState.idle);
          if (message.isNotEmpty) joinError = message;
        } else if (name == 'discovered') {
          discovered = ((msg['rooms'] as List<dynamic>?) ?? []).cast<Map<String, dynamic>>();
        } else if (name == 'file-offer' || name == 'file-progress' || name == 'file-done') {
          _applyTransferEvent(name, msg);
        }
      case 'env':
        admin = msg['admin'] == true;
        canElevate = msg['canElevate'] == true;
      case 'core-exit':
        // 提权交接期间,或新核心已接管时,旧连接的退出事件不再影响状态。
        if (!_elevating && !bridge.running) {
          bridgeReady = false;
          admin = null;
          canElevate = false;
          bridgeProblem = (msg['message'] as String?) ?? '核心进程已退出';
          _setRoom(RoomState.idle);
        }
    }
    notifyListeners();
  }

  void _applyRoomFields(Map<String, dynamic> fields) {
    final codeField = fields['code'] as String?;
    final self = fields['self'] as String?;
    final host = fields['host'] as String?;
    final state = fields['state'] as String?;
    if (state != null && state.isNotEmpty) {
      room = RoomState.values.firstWhere((r) => r.name == state, orElse: () => room);
    }
    if (codeField != null && codeField.isNotEmpty) code = codeField;
    if (self != null && self.isNotEmpty) selfIp = _ipOnly(self);
    if (host != null && host.isNotEmpty) hostName = host;
    final lanField = fields['lan'];
    if (lanField is List) {
      lanAddrs = lanField.whereType<String>().toList();
    }
  }

  void _setRoom(RoomState s) {
    room = s;
    if (s == RoomState.idle) {
      code = null;
      selfIp = null;
      hostName = null;
      members = [];
      transfers = [];
      joinLog = [];
      joinError = null;
      discovered = [];
      joiningCode = null;
      _joinFromDiscovery = false;
      _joinPending = false;
      _lastJoinId = '';
      _lastHostId = '';
      lanAddrs = [];
      publicAddr = null;
      stunRunning = false;
      stunError = null;
      _stunSeq++;
    }
  }

  // ---- 工具 ----
  // 'K7Q2M9XD' → 'K7Q2 M9XD';已带空格或连字符的输入先归一。
  String _displayOf(String raw) {
    final b = StringBuffer();
    for (final r in raw.runes) {
      final ch = String.fromCharCode(r).toUpperCase();
      final ok = (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
      if (ok) b.write(ch);
    }
    final s = b.toString();
    if (s.length <= 4) return s;
    return '${s.substring(0, 4)} ${s.substring(4)}';
  }

  // 与核心信标里的房间码同形:去掉展示用空格。
  String _normalized(String raw) => _displayOf(raw).replaceAll(' ', '');

  // 房主地址缺省端口时补默认端口。
  String _peerWithPort(String peer) {
    final p = peer.trim();
    if (p.contains(':')) return p;
    return '$p:${prefs.port}';
  }

  // '10.66.7.2/24' → '10.66.7.2'
  String _ipOnly(String cidr) {
    final i = cidr.indexOf('/');
    return i == -1 ? cidr : cidr.substring(0, i);
  }

  // 在房人数:主机侧名册不含房主,补上自己;成员侧名册只有房主一行。
  int get memberCount {    switch (room) {
      case RoomState.hosting:
        return members.length + 1;
      case RoomState.joined:
        return members.length + 1; // 房主一行 + 自己
      default:
        return 0;
    }
  }

  // 房主行地址:成员侧核心不报主机房间内地址,按段首地址惯例推导。
  String get hostAddr {
    if (room != RoomState.joined) return '—';
    final ip = selfIp ?? '';
    final parts = ip.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.${parts[1]}.${parts[2]}.1';
    }
    return '—';
  }

  // 邀请里带的地址:优先公网映射;没有公网时用第一个局域网地址。
  String? get invitePeer {
    if (publicAddr != null && publicAddr!.isNotEmpty) return publicAddr;
    if (lanAddrs.isNotEmpty) return lanAddrs.first;
    return null;
  }

  int? get publicPort {
    final a = publicAddr;
    if (a == null) return null;
    final i = a.lastIndexOf(':');
    if (i < 0) return null;
    return int.tryParse(a.substring(i + 1));
  }

  bool get inRoom => room == RoomState.hosting || room == RoomState.joined;

  // 某一间发现房是否正在加入:只让被点的那张卡显示进度。
  bool isFoundJoining(String code) => room == RoomState.joining && joiningCode == code;

  // 沿树下发 AppState 的轻量 Provider 的取用口。
  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()!.notifier!;
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required AppState notifier, required super.child})
      : super(notifier: notifier);
}
