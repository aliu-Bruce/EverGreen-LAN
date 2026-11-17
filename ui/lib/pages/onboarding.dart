// 首次启动引导:三步覆盖层,像素树开场,权限边界讲清楚。
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../core/app_state.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class Onboarding extends StatefulWidget {
  const Onboarding({super.key});

  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  int _step = 1;

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;

    return OverlayScaffold(
      scrim: c.overlay,
      onTapBarrier: () => _finish(app),
      child: Container(
        width: 560,
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: c.panel,
          border: Border.all(color: c.line2),
          borderRadius: BorderRadius.circular(22),
          boxShadow: c.bigShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
              child: _buildStep(app, c, key: ValueKey(_step)),
            ),
            // 圆点:当前项拉长为胶囊
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 1; i <= 3; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      margin: const EdgeInsets.symmetric(horizontal: 3.5),
                      height: 7,
                      width: i == _step ? 20 : 7,
                      decoration: BoxDecoration(
                        color: i == _step ? c.acc : c.line2,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                EgButton(
                  label: app.langs.t('btn.skip'),
                  small: true,
                  onPressed: () => _finish(app),
                ),
                EgButton(
                  label: _step == 3 ? app.langs.t('btn.start') : app.langs.t('btn.next'),
                  kind: EgBtnKind.primary,
                  small: true,
                  onPressed: () {
                    if (_step == 3) {
                      _finish(app);
                    } else {
                      setState(() => _step += 1);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(AppState app, EgColors c, {required Key key}) {
    switch (_step) {
      case 1:
        return Column(
          key: key,
          children: [
            PixelArt(rects: egTreeArt(c), cols: 16, rows: 12, scale: 8.75),
            const SizedBox(height: 18),
            Text(app.langs.t('ob.w1'), style: egDisplay(c, size: 24, letterSpacing: -0.01), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(app.langs.t('ob.w2'), textAlign: TextAlign.center, style: egText(c, size: 13.5, color: c.muted, height: 1.6)),
            const SizedBox(height: 8),
            Text(app.langs.t('ob.w3'), textAlign: TextAlign.center, style: egText(c, size: 13.5, color: c.muted, height: 1.6)),
          ],
        );
      case 2:
        return Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(app.langs.t('ob.p1'), textAlign: TextAlign.center, style: egDisplay(c, size: 24, letterSpacing: -0.01)),
            const SizedBox(height: 10),
            Text(app.langs.t('ob.p2'), textAlign: TextAlign.center, style: egText(c, size: 13.5, color: c.muted, height: 1.6)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: c.panel2,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.langs.t('ob.boundary'), style: egText(c, size: 12.5, weight: FontWeight.w600, color: c.text)),
                  const SizedBox(height: 4),
                  for (final (i, key) in ['ob.b1', 'ob.b2', 'ob.b3'].indexed)
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('0${i + 1}', style: egMono(c, size: 11.5, color: c.acc)),
                          const SizedBox(width: 12),
                          Expanded(child: Text(app.langs.t(key), style: egText(c, size: 13, color: c.muted, height: 1.5))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      default:
        return Column(
          key: key,
          children: [
            const SizedBox(height: 60),
            Text(app.langs.t('ob.r1'), style: egDisplay(c, size: 24, letterSpacing: -0.01)),
            const SizedBox(height: 10),
            Text(app.langs.t('ob.r2'), textAlign: TextAlign.center, style: egText(c, size: 13.5, color: c.muted, height: 1.6)),
            const SizedBox(height: 8),
            Text(app.langs.t('ob.r3'), textAlign: TextAlign.center, style: egText(c, size: 13.5, color: c.muted, height: 1.6)),
          ],
        );
    }
  }

  void _finish(AppState app) => app.finishOnboarding();
}

// 覆盖层骨架:模糊 + 半透明底,点外部即视为跳过。
class OverlayScaffold extends StatelessWidget {
  final Color scrim;
  final Widget child;
  final VoidCallback? onTapBarrier;
  const OverlayScaffold({super.key, required this.scrim, required this.child, this.onTapBarrier});

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Positioned.fill(
      child: Stack(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: onTapBarrier,
              child: reduced
                  ? Container(color: scrim)
                  : BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(color: scrim),
                    ),
            ),
          ),
          Center(child: child),
        ],
      ),
    );
  }
}
