// 应用状态机:偏好、语言、核心桥与房间状态集中于此,ChangeNotifier 通知界面。
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../i18n.dart';
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

class AppState extends ChangeNotifier {
  final Prefs prefs = Prefs();
  final EgLangs langs = EgLangs();
  final IpcBridge bridge = IpcBridge();

  bool bridgeReady = false;
  String? bridgeProblem;

  // 运行权限:核心报告的是否已提权、能否一键提权。
  bool? admin;
  bool canElevate = false;

  RoomState room = RoomState.idle;
  String? code;      // 房间码展示形态 XXXX XXXX
  String? selfIp;    // 本机虚拟地址
  String? hostName;  // 房主机显示名(成员侧)
  List<Map<String, dynamic>> members = [];

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
      await bridge.start(path);
      bridgeReady = true;
      _sub = bridge.messages.listen(_onMessage, onError: (Object e) {
        bridgeProblem = e.toString();
        bridgeReady = false;
        _setRoom(RoomState.idle);
        notifyListeners();
      });
      unawaited(bridge.request({'op': 'status'}, timeout: const Duration(seconds: 3)).catchError((_) => <String, dynamic>{}));
      unawaited(bridge.request({'op': 'env'}, timeout: const Duration(seconds: 3)).catchError((_) => <String, dynamic>{}));
    } catch (e) {
      bridgeProblem = e.toString();
    }
    notifyListeners();
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

  // 以管理员权限重启界面;成功返回 null,界面随后退出让新实例接管。
  Future<String?> restartAsAdmin() async {
    if (!bridgeReady) return '核心进程未运行';
    try {
      final ack = await bridge.request({
        'op': 'restart-admin',
        'exe': Platform.resolvedExecutable,
      }, timeout: const Duration(seconds: 90));
      if (ack['relaunched'] != true) return '当前已是管理员权限';
      return null;
    } on IpcError catch (e) {
      return e.message;
    }
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
        }
      case 'env':
        admin = msg['admin'] == true;
        canElevate = msg['canElevate'] == true;
      case 'core-exit':
        bridgeReady = false;
        admin = null;
        canElevate = false;
        bridgeProblem = (msg['message'] as String?) ?? '核心进程已退出';
        _setRoom(RoomState.idle);
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
