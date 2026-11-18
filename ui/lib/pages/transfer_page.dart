// 传输页(预留):随插件系统发布的占位,只传达方向与边界。
import 'package:material_ui/material_ui.dart';

import '../core/app_state.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    return StaggerIn(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.langs.t('tr.title'), style: egDisplay(c, size: 30, letterSpacing: -0.01, height: 1.2)),
            const SizedBox(width: 14),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(app.langs.t('tr.meta'), style: egText(c, size: 12.5, color: c.muted)),
            ),
          ],
        ),
        // 原型的 .drop 自身就是一张虚线卡:虚线边即边界,无面板底;
        // 悬停时描边点亮、底色浮现、整体上浮 2px。
        Padding(
          padding: const EdgeInsets.only(top: 22),
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
              child: DashedBorder(
                color: _hover ? c.acc : c.line2,
                radius: 18,
                child: Container(
                  color: _hover ? c.panel2 : null,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
                  child: Column(
                    children: [
                      PixelArt(rects: egChainArt(c), cols: 14, rows: 10, scale: 7),
                      const SizedBox(height: 10),
                      Text(app.langs.t('tr.drop'), style: egDisplay(c, size: 16)),
                      const SizedBox(height: 8),
                      Text(app.langs.t('tr.dropSub'), style: egText(c, size: 12.5, color: c.faint)),
                      const SizedBox(height: 14),
                      EgChip(app.langs.t('chip.wip')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
