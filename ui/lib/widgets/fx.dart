// 动效与小部件:克制的入场编排、真实数据用的等宽件、品牌像素语言。
// 原则:一切出现即淡入并上浮,次序即层级;系统开启"减少动态效果"时全部瞬时。
import 'package:material_ui/material_ui.dart';

import '../theme.dart';

// 页面入场:逐个子元素上浮淡入,60ms 递进;旧页离场不演,新页独自入。
class StaggerIn extends StatefulWidget {
  final List<Widget> children;
  const StaggerIn({super.key, required this.children});

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );
  bool _started = false;

  // 入场判定放在 didChangeDependencies:initState 里不可查询继承。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctl.value = 1;
    } else {
      _ctl.forward();
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              _StaggerChild(
                controller: _ctl,
                index: i,
                child: widget.children[i],
              ),
          ],
        );
      },
    );
  }
}

class _StaggerChild extends StatelessWidget {
  final AnimationController controller;
  final int index;
  final Widget child;
  const _StaggerChild({required this.controller, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) return child;
    final start = (index * 0.06).clamp(0.0, 0.6);
    final curve = CurvedAnimation(
      parent: controller,
      curve: Interval(start, 1.0, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: curve,
      builder: (context, _) {
        final v = curve.value;
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 10),
            child: child,
          ),
        );
      },
    );
  }
}

// 三点跳动的进度指示:等宽终端行的"正在做"状态。
class HopSpinner extends StatefulWidget {
  final EgColors c;
  const HopSpinner({super.key, required this.c});

  @override
  State<HopSpinner> createState() => _HopSpinnerState();
}

class _HopSpinnerState extends State<HopSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!MediaQuery.disableAnimationsOf(context)) _ctl.repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.disableAnimationsOf(context) ? 0.0 : 6.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          AnimatedBuilder(
            animation: _ctl,
            builder: (context, _) {
              final phase = (_ctl.value - i * 0.15) % 1.0;
              final hop = phase < 0.6 ? _bounce(phase / 0.6) : 0.0;
              return Container(
                margin: const EdgeInsets.only(right: 4),
                width: 9,
                height: 9,
                color: widget.c.acc,
                transform: Matrix4.translationValues(0, -hop * size, 0),
                alignment: Alignment.center,
              );
            },
          ),
      ],
    );
  }

  // 0→1→0 的单跳曲线。
  double _bounce(double t) {
    final s = t * 2 <= 1 ? t * 2 : 2 - t * 2;
    return Curves.easeOutCubic.transform(s);
  }
}

// 状态灯:ok/warn/bad 三色;pulse 用于"活着的"连接指示。
class EgLed extends StatelessWidget {
  final Color color;
  final bool pulse;
  const EgLed({super.key, required this.color, this.pulse = false});

  @override
  Widget build(BuildContext context) {
    Widget dot = Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    if (pulse && !MediaQuery.disableAnimationsOf(context)) {
      dot = _Pulsing(child: dot);
    }
    return dot;
  }
}

class _Pulsing extends StatefulWidget {
  final Widget child;
  const _Pulsing({required this.child});

  @override
  State<_Pulsing> createState() => _PulsingState();
}

class _PulsingState extends State<_Pulsing> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    _ctl.repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: Tween(begin: 1.0, end: 0.45).animate(_ctl), child: widget.child);
  }
}

// 像素画:品牌像素语言(引导页树、传输页链环),shape-rendering 由整数栅格保证。
class PixelArt extends StatelessWidget {
  final List<PixelRect> rects;
  final int cols; // 栅格列数
  final int rows;
  final double scale;
  const PixelArt({super.key, required this.rects, required this.cols, required this.rows, this.scale = 10});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(cols * scale + 0.0, rows * scale + 0.0),
      painter: _PixelPainter(rects, cols, rows, scale),
    );
  }
}

class PixelRect {
  final int x, y, w, h;
  final Color color;
  const PixelRect(this.x, this.y, this.w, this.h, this.color);
}

class _PixelPainter extends CustomPainter {
  final List<PixelRect> rects;
  final int cols, rows;
  final double scale;
  _PixelPainter(this.rects, this.cols, this.rows, this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final r in rects) {
      paint.color = r.color;
      canvas.drawRect(
        Rect.fromLTWH(r.x * scale, r.y * scale, r.w * scale, r.h * scale),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PixelPainter oldDelegate) => oldDelegate.rects != rects;
}

// 引导页像素树(16x12),与原型同一份栅格数据。
List<PixelRect> egTreeArt(EgColors c) {
  const g1 = Color(0xFF7BEBA6);
  const g2 = Color(0xFF4CC57F);
  const g3 = Color(0xFF2E8A57);
  const g4 = Color(0xFF3AA868);
  const hl = Color(0xFFA9F2C2);
  const trunk1 = Color(0xFF8B5E46);
  const trunk2 = Color(0xFF6E4636);
  return const [
    PixelRect(7, 0, 2, 1, g1),
    PixelRect(6, 1, 4, 1, g2),
    PixelRect(5, 2, 6, 1, g2),
    PixelRect(6, 3, 4, 1, g3),
    PixelRect(4, 4, 8, 1, g2),
    PixelRect(3, 5, 10, 1, g4),
    PixelRect(4, 6, 8, 1, g3),
    PixelRect(2, 7, 12, 1, g2),
    PixelRect(1, 8, 14, 1, g4),
    PixelRect(2, 9, 12, 1, g3),
    PixelRect(7, 10, 2, 2, trunk1),
    PixelRect(8, 10, 1, 2, trunk2),
    PixelRect(7, 1, 1, 1, hl),
    PixelRect(5, 4, 1, 1, hl),
    PixelRect(3, 7, 1, 1, hl),
  ];
}

// 传输页像素链环(14x10)。
List<PixelRect> egChainArt(EgColors c) {
  const a = Color(0xFF4CC57F);
  const b = Color(0xFFA9F2C2);
  return const [
    PixelRect(1, 0, 6, 1, a),
    PixelRect(0, 1, 1, 3, a),
    PixelRect(7, 1, 1, 3, a),
    PixelRect(1, 4, 6, 1, a),
    PixelRect(5, 4, 6, 1, b),
    PixelRect(4, 5, 1, 3, b),
    PixelRect(11, 5, 1, 3, b),
    PixelRect(5, 8, 6, 1, b),
  ];
}

// 房间码不完整就点连接:输入区左右抖动一次。
class ShakeController {
  late final AnimationController ctl;
  late final void Function() ensure;

  ShakeController(TickerProvider vsync, void Function() notify) {
    ctl = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 400));
    ctl.addListener(notify);
    ensure = () {
      if (ctl.isAnimating) return;
      ctl.forward(from: 0);
    };
  }

  // 关键帧 (0,0)(0.2,-5)(0.4,5)(0.6,-5)(0.8,5)(1,0) 的线性插值。
  double get dx {
    final t = ctl.value;
    const ks = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0];
    const vs = [0.0, -5.0, 5.0, -5.0, 5.0, 0.0];
    for (var i = 0; i < ks.length - 1; i++) {
      if (t <= ks[i + 1]) {
        final k = (t - ks[i]) / (ks[i + 1] - ks[i]);
        return vs[i] + (vs[i + 1] - vs[i]) * k;
      }
    }
    return 0;
  }
}
