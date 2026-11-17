// 主页:本机信息条、两块主行动、局域网发现(空态)。
import 'package:material_ui/material_ui.dart';

import '../core/app_state.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class HomePage extends StatelessWidget {
  final void Function(EgPageTarget target) go;
  const HomePage({super.key, required this.go});

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final inRoom = app.inRoom;

    return StaggerIn(
      children: [
        // 本机信息条
        Container(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 18),
          margin: const EdgeInsets.only(bottom: 28),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
          child: Row(
            children: [
              Text(app.langs.t('home.device'), style: egText(c, size: 13, weight: FontWeight.w600)),
              const SizedBox(width: 22),
              Text(app.prefs.name, style: egMono(c, size: 12.5, color: c.text)),
              if (inRoom) ...[
                const SizedBox(width: 22),
                Text(app.selfIp ?? '—', style: egMono(c, size: 12.5, color: c.muted)),
              ],
              const SizedBox(width: 22),
              Text('MTU ${app.prefs.mtu}', style: egMono(c, size: 12.5, color: c.muted)),
              const SizedBox(width: 22),
              Text('UDP ${app.prefs.port}', style: egMono(c, size: 12.5, color: c.muted)),
              const Spacer(),
              EgButton(
                label: app.langs.t('home.rename'),
                small: true,
                onPressed: () => showRenameDialog(context, app),
              ),
            ],
          ),
        ),

        // 两块主行动:创建 1.7fr / 加入 1fr
        // 在垂直滚动区里高度无界,Row 的 stretch 需 IntrinsicHeight 给出有界高度,
        // 两块以较高者取齐。
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 17,
                child: EgCTA(
                  title: app.langs.t('home.create'),
                  sub: app.langs.t('home.createSub'),
                  primary: true,
                  onTap: () => go(EgPageTarget.create),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 10,
                child: EgCTA(
                  title: app.langs.t('home.join'),
                  sub: app.langs.t('home.joinSub'),
                  onTap: () => go(EgPageTarget.join),
                ),
              ),
            ],
          ),
        ),

        Sect(title: app.langs.t('home.found'), sub: app.langs.t('home.foundSub')),
        Text(
          app.langs.t('home.empty'),
          style: egText(c, size: 12.5, color: c.faint),
        ),
      ],
    );
  }
}

class EgCTA extends StatefulWidget {
  final String title;
  final String sub;
  final bool primary;
  final VoidCallback onTap;
  const EgCTA({super.key, required this.title, required this.sub, required this.onTap, this.primary = false});

  @override
  State<EgCTA> createState() => _EgCTAState();
}

class _EgCTAState extends State<EgCTA> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final bg = widget.primary ? c.acc : c.panel;
    final fg = widget.primary ? c.accInk : c.text;
    final border = widget.primary ? c.acc : c.line2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: widget.primary ? c.accShadow : c.panelShadow,
        ),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: border)),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(18),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) return fg.withValues(alpha: 0.12);
              if (states.contains(WidgetState.hovered)) return fg.withValues(alpha: 0.08);
              return Colors.transparent;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: egDisplay(c, size: 18, color: fg)),
                  const SizedBox(height: 4),
                  Text(widget.sub, style: egText(c, size: 12.5, color: fg.withValues(alpha: 0.78), height: 1.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 改名:清空则恢复默认名规则。
Future<void> showRenameDialog(BuildContext context, AppState app) async {
  final c = Eg.of(context).c;
  final ctrl = TextEditingController(text: app.prefs.name);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => EgSkinDialog(
      title: app.langs.t('home.rename'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(app.langs.t('set.nameHint'), style: egText(c, size: 12.5, color: c.muted, height: 1.6)),
          const SizedBox(height: 14),
          EgInput(controller: ctrl, width: 260, maxLength: 24, center: false, mono: false),
        ],
      ),
      actions: [
        EgButton(label: app.langs.t('btn.close'), small: true, onPressed: () => Navigator.of(context).pop(false)),
        EgButton(
          label: app.langs.t('btn.connect'),
          kind: EgBtnKind.primary,
          small: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  if (ok == true) {
    final v = ctrl.text.trim();
    if (v.isNotEmpty) app.setName(v);
  }
}

// 弹窗骨架在 widgets/eg.dart(EgSkinDialog),此处只有改名逻辑。

// 页面跳转目标:主页上的两种行动。
enum EgPageTarget { create, join }
