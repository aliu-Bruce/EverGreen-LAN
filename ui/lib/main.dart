// EverGreen LAN 界面入口:温室外壳(侧栏/顶栏)、页面路由与引导覆盖。
import 'package:material_ui/material_ui.dart';

import 'core/app_state.dart';
import 'core/prefs.dart';
import 'pages/home_page.dart';
import 'pages/join_page.dart';
import 'pages/onboarding.dart';
import 'pages/room_page.dart';
import 'pages/settings_page.dart';
import 'pages/transfer_page.dart';
import 'theme.dart';
import 'widgets/eg.dart';
import 'widgets/fx.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  // 先把偏好、语言包与核心桥就绪,再绘首帧:首帧即完整文案,不闪键名。
  await app.init();
  runApp(EgApp(app: app));
}

class EgApp extends StatelessWidget {
  final AppState app;
  const EgApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final dark = switch (app.prefs.themeMode) {
          EgThemeMode.light => false,
          EgThemeMode.dark => true,
          // MaterialApp 之上没有 MediaQuery,直接读平台侧的亮度。
          EgThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
        };
        final appearance = app.appearance;
        final lightTokens = appearance.colorsFor(Brightness.light);
        final darkTokens = appearance.colorsFor(Brightness.dark);
        final tokens = dark ? darkTokens : lightTokens;
        return MaterialApp(
          title: 'EverGreen LAN',
          debugShowCheckedModeBanner: false,
          theme: egTheme(lightTokens),
          darkTheme: egTheme(darkTokens),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          // 与自定义令牌的过渡同速,系统控件与自绘控件一起完成换色。
          themeAnimationDuration: const Duration(milliseconds: 420),
          themeAnimationCurve: const Cubic(0.2, 0, 0, 1),
          builder: (context, child) => EgMotion(
            colors: tokens,
            child: AppStateScope(notifier: app, child: child ?? const SizedBox.shrink()),
          ),
          home: const Shell(),
        );
      },
    );
  }
}

enum ShellPage { home, room, transfer, settings, join }

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  ShellPage _page = ShellPage.home;
  bool _wasInRoom = false;

  // 状态变化时才自动跳转:刚入房→房间页,刚离房→回主页。
  // 手动点导航不受影响:空闲时也允许看房间页的空态说明。
  void _followState() {
    final app = AppState.of(context);
    if (!mounted) return;
    final nowIn = app.inRoom;
    if (nowIn && !_wasInRoom) {
      if (_page != ShellPage.room) setState(() => _page = ShellPage.room);
    } else if (!nowIn && _wasInRoom) {
      if (_page == ShellPage.room) setState(() => _page = ShellPage.home);
    }
    _wasInRoom = nowIn;
  }

  void _goCreate() async {
    final app = AppState.of(context);
    final err = await app.createRoom();
    if (!mounted) return;
    if (err != null) {
      _showCoreError(context, err);
    } else {
      setState(() => _page = ShellPage.room);
    }
  }

  void _goJoin() => setState(() => _page = ShellPage.join);

  void _showCoreError(BuildContext context, String message) {
    final app = AppState.of(context);
    // 核心的错误文案只在权限不足时附带这句;其余失败重启也无济于事。
    final needsAdmin = message.contains('管理员权限') || message.contains('权限被拒');
    showDialog<void>(
      context: context,
      builder: (context) => _CoreErrorDialog(
        message: message,
        canRestart: needsAdmin && app.canElevate && app.admin != true,
        onRetry: _goCreate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    WidgetsBinding.instance.addPostFrameCallback((_) => _followState());

    final topMode = app.prefs.navMode == EgNavMode.top;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: EgMist()),
          Positioned.fill(
            child: Column(
              children: [
                if (topMode) TopBar(page: _page, onGo: (p) => setState(() => _page = p)),
                Expanded(
                  child: Row(
                    children: [
                      if (!topMode) Rail(page: _page, onGo: (p) => setState(() => _page = p)),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(42, 36, 42, 60),
                          child: Center(
                            widthFactor: 1,
                            // 高度也随内容:页面顶对齐,短内容不再飘在页面中部。
                            heightFactor: 1,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 880),
                              child: _PageSwitcher(
                                page: _page,
                                goHome: () => setState(() => _page = ShellPage.home),
                                onCreate: _goCreate,
                                onJoin: _goJoin,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!app.prefs.onboarded) Onboarding(),
          // 核心缺失或退出:底部横幅提示
          if (app.bridgeProblem != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: EgErrorTerm(
                title: app.bridgeProblem!,
                body: '',
              ),
            ),
        ],
      ),
    );
  }
}

// 核心错误弹窗:权限不足时直接给出提权入口,而不是只让用户关掉。
class _CoreErrorDialog extends StatefulWidget {
  final String message;
  final bool canRestart;
  final VoidCallback? onRetry;
  const _CoreErrorDialog({required this.message, required this.canRestart, this.onRetry});

  @override
  State<_CoreErrorDialog> createState() => _CoreErrorDialogState();
}

class _CoreErrorDialogState extends State<_CoreErrorDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _restart() async {
    final app = AppState.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await app.elevateCore();
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    final retry = widget.onRetry;
    Navigator.of(context).pop();
    retry?.call(); // 核心已提权,直接重试刚才的开房动作
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    return Dialog(
      backgroundColor: c.badDim,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.bad)),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              widget.message,
              style: egMono(c, size: 12.5, weight: FontWeight.w700, color: c.bad, height: 1.6),
            ),
            if (widget.canRestart) ...[
              const SizedBox(height: 10),
              Text(
                app.langs.t('set.permUserHint'),
                style: egText(c, size: 12, color: c.muted, height: 1.6),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: egText(c, size: 12, color: c.bad, height: 1.5)),
            ],
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EgButton(
                    label: app.langs.t('btn.close'),
                    small: true,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                  if (widget.canRestart) ...[
                    const SizedBox(width: 8),
                    EgButton(
                      label: _busy ? app.langs.t('set.permRestarting') : app.langs.t('btn.restartAdmin'),
                      kind: EgBtnKind.primary,
                      small: true,
                      onPressed: _busy ? null : _restart,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageSwitcher extends StatelessWidget {
  final ShellPage page;
  final VoidCallback goHome;
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  const _PageSwitcher({required this.page, required this.goHome, required this.onCreate, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (page) {
      ShellPage.home => HomePage(
          key: const ValueKey('home'),
          go: (target) {
            switch (target) {
              case EgPageTarget.join:
                onJoin();
              case EgPageTarget.create:
                onCreate();
            }
          },
        ),
      ShellPage.join => JoinPage(key: const ValueKey('join'), goHome: goHome),
      ShellPage.room => RoomPage(key: const ValueKey('room'), goHome: goHome, onCreate: onCreate, onJoin: onJoin),
      ShellPage.transfer => const TransferPage(),
      ShellPage.settings => const SettingsPage(),
    };
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(curved),
            child: ScaleTransition(
              scale: Tween(begin: 0.985, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [...previousChildren, if (currentChild != null) currentChild],
      ),
      child: child,
    );
  }
}

// 侧栏:品牌、四个导航项、状态与身份;活动项以整栏唯一的滑动点表达。
class Rail extends StatefulWidget {
  final ShellPage page;
  final ValueChanged<ShellPage> onGo;
  const Rail({super.key, required this.page, required this.onGo});

  @override
  State<Rail> createState() => _RailState();
}

class _RailState extends State<Rail> with SingleTickerProviderStateMixin {
  // M3 emphasized 缓动,与 mockup 的 --ease-emph 一致。
  static const Cubic _ease = Cubic(0.2, 0, 0, 1);

  late final AnimationController _dotCtl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  final GlobalKey _anchor = GlobalKey();
  final Map<ShellPage, GlobalKey> _sqs = {
    for (final p in const [ShellPage.home, ShellPage.room, ShellPage.transfer, ShellPage.settings])
      p: GlobalKey(),
  };
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  bool _shown = false;
  ShellPage? _placedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  @override
  void didUpdateWidget(Rail oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  @override
  void dispose() {
    _dotCtl.dispose();
    super.dispose();
  }

  // 逐项测量占位槽位置:切页时滑动,首次与内容变化时瞬时就位。
  void _place() {
    if (!mounted) return;
    final anchorCtx = _anchor.currentContext;
    final sqCtx = _sqs[widget.page]?.currentContext;
    if (anchorCtx == null || sqCtx == null) {
      if (_shown) setState(() => _shown = false);
      return;
    }
    final anchor = anchorCtx.findRenderObject()! as RenderBox;
    final sq = sqCtx.findRenderObject()! as RenderBox;
    final p = sq.localToGlobal(Offset.zero, ancestor: anchor);
    final pos = Offset(p.dx, p.dy + sq.size.height / 2 - 2.5);
    final animate = _shown && _placedAt != widget.page && !MediaQuery.disableAnimationsOf(context);
    setState(() {
      if (animate) {
        // 从当前显示位置出发滑向新位置。
        final k = _ease.transform(_dotCtl.value);
        _from = Offset.lerp(_from, _to, k)!;
        _to = pos;
        _dotCtl.forward(from: 0);
      } else {
        _from = pos;
        _to = pos;
        _dotCtl.value = 0;
      }
      _shown = true;
      _placedAt = widget.page;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final t = (k) => app.langs.t(k);
    final page = widget.page;
    final onGo = widget.onGo;
    final incoming = app.transfers.where((t) => t.awaiting).length;

    final items = <(ShellPage, IconData, String, String)>[
      (ShellPage.home, Icons.home_outlined, t('nav.home'), ''),
      (ShellPage.room, Icons.group_outlined, t('nav.room'), app.inRoom ? '${app.memberCount}/8' : ''),
      (ShellPage.transfer, Icons.swap_horiz, t('nav.transfer'), incoming > 0 ? '$incoming' : ''),
      (ShellPage.settings, Icons.settings_outlined, t('nav.settings'), ''),
    ];

    return Container(
      width: 216,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 18),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), boxShadow: c.panelShadow),
                  child: const Image(image: AssetImage('assets/icon/icon.png'), fit: BoxFit.cover),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('EGLAN', style: egDisplay(c, size: 17, letterSpacing: 0.02, height: 1.2)),
                    Text('v0.1.0-dev', style: egMono(c, size: 10, color: c.faint)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              key: _anchor,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (target, icon, label, cnt) in items)
                      _NavItem(
                        c: c,
                        icon: icon,
                        label: label,
                        cnt: cnt,
                        sqKey: _sqs[target],
                        active: page == target,
                        onTap: () => onGo(target),
                      ),
                  ],
                ),
                // 滑点:整栏唯一的状态点,切页时自旧项滑向新项,途中拉伸后收拢。
                AnimatedBuilder(
                  animation: _dotCtl,
                  builder: (context, _) {
                    final raw = _dotCtl.value;
                    final s = 4 * raw * (1 - raw); // 途中拉伸的抛物线,峰值 1
                    final pos = Offset.lerp(_from, _to, _ease.transform(raw))!;
                    return Positioned(
                      left: pos.dx,
                      top: pos.dy,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _shown ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.diagonal3Values(1 - 0.2 * s, 1 + 1.4 * s, 1),
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(color: c.acc, borderRadius: BorderRadius.circular(2)),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    EgLed(
                      color: switch (app.room) {
                        RoomState.idle => c.faint,
                        RoomState.joining => c.warn,
                        _ => c.acc,
                      },
                      pulse: app.room != RoomState.idle,
                    ),
                    const SizedBox(width: 8),
                    ScrambleText(
                      text: switch (app.room) {
                        RoomState.idle => t('status.idle'),
                        RoomState.joining => t('status.joining'),
                        RoomState.hosting || RoomState.joined => t('status.tun'),
                      },
                      style: egMono(c, size: 11, color: c.muted),
                    ),
                  ],
                ),
                if (app.inRoom) ...[
                  const SizedBox(height: 5),
                  ScrambleText(
                    text: '${app.selfIp ?? '—'} · MTU ${app.prefs.mtu}',
                    style: egMono(c, size: 11, color: c.faint),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.accDim, borderRadius: BorderRadius.circular(9)),
                  child: Text(
                    app.prefs.name.isEmpty ? '·' : app.prefs.name[0].toUpperCase(),
                    style: egText(c, size: 12.5, weight: FontWeight.w600, color: c.acc),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    app.prefs.name,
                    style: egText(c, size: 12.5, weight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// 侧栏导航项:悬停面板底色,活动项同样;图标在活动时染品牌绿。
// 行首保留 5px 透明占位槽(.sq),滑点由侧栏统一测量并盖在其上。
class _NavItem extends StatefulWidget {
  final EgColors c;
  final IconData icon;
  final String label;
  final String cnt;
  final bool active;
  final VoidCallback onTap;
  final Key? sqKey;
  const _NavItem({required this.c, required this.icon, required this.label, required this.cnt, required this.active, required this.onTap, this.sqKey});

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: (widget.active || _hover) ? c.panel2 : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                Container(
                  key: widget.sqKey,
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(right: 5),
                  color: Colors.transparent,
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  transform: Matrix4.translationValues(_hover && !widget.active ? 2 : 0, 0, 0),
                  child: Icon(widget.icon, size: 17, color: widget.active ? c.acc : (c.muted)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    style: egText(c, size: 13.5, color: widget.active ? c.text : c.muted, height: 1.4),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.cnt.isNotEmpty)
                  Text(widget.cnt, style: egMono(c, size: 11, color: c.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 顶栏导航模式:品牌 + 页签(下滑线指示) + 连接状态。
class TopBar extends StatefulWidget {
  final ShellPage page;
  final ValueChanged<ShellPage> onGo;
  const TopBar({super.key, required this.page, required this.onGo});

  @override
  State<TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<TopBar> with SingleTickerProviderStateMixin {
  // M3 emphasized 缓动,与 mockup 的 --ease-emph 一致。
  static const Cubic _ease = Cubic(0.2, 0, 0, 1);

  late final AnimationController _indCtl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  final GlobalKey _anchor = GlobalKey();
  final Map<ShellPage, GlobalKey> _tabs = {
    for (final p in const [ShellPage.home, ShellPage.room, ShellPage.transfer, ShellPage.settings])
      p: GlobalKey(),
  };
  double _fromL = 0, _toL = 0, _fromW = 0, _toW = 0;
  bool _shown = false;
  ShellPage? _placedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  @override
  void didUpdateWidget(TopBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  @override
  void dispose() {
    _indCtl.dispose();
    super.dispose();
  }

  // 测激活页签的位置:切页时滑线移动,首次与内容变化时瞬时就位。
  void _place() {
    if (!mounted) return;
    final anchorCtx = _anchor.currentContext;
    final tabCtx = _tabs[widget.page]?.currentContext;
    if (anchorCtx == null || tabCtx == null) {
      if (_shown) setState(() => _shown = false);
      return;
    }
    final anchor = anchorCtx.findRenderObject()! as RenderBox;
    final tab = tabCtx.findRenderObject()! as RenderBox;
    final p = tab.localToGlobal(Offset.zero, ancestor: anchor);
    final l = p.dx + 15;
    final w = tab.size.width - 30;
    final animate = _shown && _placedAt != widget.page && !MediaQuery.disableAnimationsOf(context);
    setState(() {
      if (animate) {
        // 从当前显示位置出发滑向新位置。
        final k = _ease.transform(_indCtl.value);
        _fromL += (_toL - _fromL) * k;
        _fromW += (_toW - _fromW) * k;
        _toL = l;
        _toW = w;
        _indCtl.forward(from: 0);
      } else {
        _fromL = _toL = l;
        _fromW = _toW = w;
        _indCtl.value = 0;
      }
      _shown = true;
      _placedAt = widget.page;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final t = (k) => app.langs.t(k);
    final page = widget.page;
    final onGo = widget.onGo;
    final incoming = app.transfers.where((t) => t.awaiting).length;

    final tabs = <(ShellPage, String, String)>[
      (ShellPage.home, t('nav.home'), ''),
      (ShellPage.room, t('nav.room'), app.inRoom ? '${app.memberCount}/8' : ''),
      (ShellPage.transfer, t('nav.transfer'), incoming > 0 ? '$incoming' : ''),
      (ShellPage.settings, t('nav.settings'), ''),
    ];

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), boxShadow: c.panelShadow),
                child: const Image(image: AssetImage('assets/icon/icon.png'), fit: BoxFit.cover),
              ),
              const SizedBox(width: 10),
              Text('EGLAN', style: egDisplay(c, size: 15, letterSpacing: 0.02)),
            ],
          ),
          Expanded(
            child: SizedBox(
              height: double.infinity,
              child: Stack(
                key: _anchor,
                children: [
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (target, label, cnt) in tabs)
                          _Tab(
                            c: c,
                            label: label,
                            cnt: cnt,
                            tabKey: _tabs[target],
                            active: page == target,
                            onTap: () => onGo(target),
                          ),
                      ],
                    ),
                  ),
                  // 下滑线:整条导航唯一的滑线,切页时自旧页签滑向新页签。
                  AnimatedBuilder(
                    animation: _indCtl,
                    builder: (context, _) {
                      final k = _ease.transform(_indCtl.value);
                      return Positioned(
                        left: _fromL + (_toL - _fromL) * k,
                        bottom: 0,
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: _shown ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              height: 2,
                              width: _fromW + (_toW - _fromW) * k,
                              decoration: BoxDecoration(
                                color: c.acc,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          if (app.inRoom)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                EgLed(color: c.acc, pulse: true),
                const SizedBox(width: 8),
                ScrambleText(
                  text: app.langs.t('status.connected', {'room': app.hostName ?? ''}),
                  style: egMono(c, size: 12, color: c.muted),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// 顶栏页签:自身只保留透明占位边,激活指示由整条导航唯一的滑线表达。
class _Tab extends StatefulWidget {
  final EgColors c;
  final String label;
  final String cnt;
  final bool active;
  final VoidCallback onTap;
  final Key? tabKey;
  const _Tab({required this.c, required this.label, required this.cnt, required this.active, required this.onTap, this.tabKey});

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          key: widget.tabKey,
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(15, 17, 15, 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.transparent, width: 2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.label, style: egText(c, size: 13.5, color: widget.active || _hover ? c.text : c.muted)),
              if (widget.cnt.isNotEmpty) ...[
                const SizedBox(width: 7),
                Text(widget.cnt, style: egMono(c, size: 11, color: c.faint)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
