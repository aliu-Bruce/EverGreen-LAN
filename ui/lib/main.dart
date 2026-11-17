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
        final tokens = dark ? EgColors.dark : EgColors.light;
        return MaterialApp(
          title: 'EverGreen LAN',
          debugShowCheckedModeBanner: false,
          theme: egTheme(EgColors.light),
          darkTheme: egTheme(EgColors.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => Eg(
            c: tokens,
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
    final c = Eg.of(context).c;
    final app = AppState.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: c.badDim,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.bad)),
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: egMono(c, size: 12.5, weight: FontWeight.w700, color: c.bad, height: 1.6)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: EgButton(
                  label: app.langs.t('btn.close'),
                  small: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
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
      ShellPage.room => RoomPage(key: const ValueKey('room'), goHome: goHome),
      ShellPage.transfer => const TransferPage(),
      ShellPage.settings => const SettingsPage(),
    };
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 140),
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [...previousChildren, if (currentChild != null) currentChild],
      ),
      child: child,
    );
  }
}

// 侧栏:品牌、四个导航项、状态与身份;活动项以整栏唯一的滑动点表达。
class Rail extends StatelessWidget {
  final ShellPage page;
  final ValueChanged<ShellPage> onGo;
  const Rail({super.key, required this.page, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final t = (k) => app.langs.t(k);

    final items = <(ShellPage, IconData, String, String)>[
      (ShellPage.home, Icons.home_outlined, t('nav.home'), ''),
      (ShellPage.room, Icons.group_outlined, t('nav.room'), app.inRoom ? '${app.memberCount}/8' : ''),
      (ShellPage.transfer, Icons.swap_horiz, t('nav.transfer'), ''),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (target, icon, label, cnt) in items)
                  _NavItem(
                    c: c,
                    icon: icon,
                    label: label,
                    cnt: cnt,
                    active: page == target,
                    onTap: () => onGo(target),
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
                    Text(
                      switch (app.room) {
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
                  Text(
                    '${app.selfIp ?? '—'} · MTU ${app.prefs.mtu}',
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
class _NavItem extends StatefulWidget {
  final EgColors c;
  final IconData icon;
  final String label;
  final String cnt;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({required this.c, required this.icon, required this.label, required this.cnt, required this.active, required this.onTap});

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
class TopBar extends StatelessWidget {
  final ShellPage page;
  final ValueChanged<ShellPage> onGo;
  const TopBar({super.key, required this.page, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final t = (k) => app.langs.t(k);

    final tabs = <(ShellPage, String, String)>[
      (ShellPage.home, t('nav.home'), ''),
      (ShellPage.room, t('nav.room'), app.inRoom ? '${app.memberCount}/8' : ''),
      (ShellPage.transfer, t('nav.transfer'), ''),
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
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (target, label, cnt) in tabs)
                _Tab(
                  c: c,
                  label: label,
                  cnt: cnt,
                  active: page == target,
                  onTap: () => onGo(target),
                ),
            ],
          ),
          const Spacer(),
          if (app.inRoom)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                EgLed(color: c.acc, pulse: true),
                const SizedBox(width: 8),
                Text(
                  app.langs.t('status.connected', {'room': app.hostName ?? ''}),
                  style: egMono(c, size: 12, color: c.muted),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  final EgColors c;
  final String label;
  final String cnt;
  final bool active;
  final VoidCallback onTap;
  const _Tab({required this.c, required this.label, required this.cnt, required this.active, required this.onTap});

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
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(15, 17, 15, 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: widget.active ? c.acc : Colors.transparent, width: 2)),
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
