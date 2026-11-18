// 动效与小部件:克制的入场编排、真实数据用的等宽件、品牌像素语言。
// 原则:一切出现即淡入并上浮,次序即层级;系统开启"减少动态效果"时全部瞬时。
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

// 页面入场:逐个子元素上浮淡入,60ms 递进;旧页离场不演,新页独自入。
class StaggerIn extends StatefulWidget {
  final List<Widget> children;
  final double spacing; // 子项间距:默认 0(各页面自管间距),设置页传原型的 16。
  const StaggerIn({super.key, required this.children, this.spacing = 0});

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
            for (var i = 0; i < widget.children.length; i++) ...[
              if (i > 0 && widget.spacing > 0) SizedBox(height: widget.spacing),
              _StaggerChild(
                controller: _ctl,
                index: i,
                child: widget.children[i],
              ),
            ],
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

// 虚线边框:原型 drop 区的 dashed 边。
class DashedBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  const DashedBorder({super.key, required this.child, required this.color, this.radius = 18});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashPainter(color, radius),
      child: Padding(padding: const EdgeInsets.all(1.5), child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: child)),
    );
  }
}

class _DashPainter extends CustomPainter {
  final Color color;
  final double radius;
  _DashPainter(this.color, this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    // 手绘虚线:等分路径成段。
    final dash = Path();
    for (final metric in path.computeMetrics()) {
      const seg = 6.0;
      var d = 0.0;
      while (d < metric.length) {
        dash.addPath(metric.extractPath(d, (d + seg).clamp(0, metric.length)), Offset.zero);
        d += seg * 2;
      }
    }
    canvas.drawPath(dash, paint);
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => color != oldDelegate.color;
}

// 把一份栅格整体平移:组合精灵时复用同一份数据。
List<PixelRect> _shiftArt(List<PixelRect> rects, int dx, int dy) =>
    [for (final r in rects) PixelRect(r.x + dx, r.y + dy, r.w, r.h, r.color)];

// 房间空态温室(20x15):棚架里种着一棵树——房间即温室,绿是恒常的。
// 棚架薄荷绿与树的提亮像素同源,内部透明以适配浅色与深色两套主题。
List<PixelRect> egRoomArt(EgColors c) {
  const frame = Color(0xFFA9F2C2);
  const ground = Color(0xFF2E8A57);
  return [
    const PixelRect(9, 0, 2, 1, frame),
    const PixelRect(8, 1, 1, 1, frame), const PixelRect(11, 1, 1, 1, frame),
    const PixelRect(7, 2, 1, 1, frame), const PixelRect(12, 2, 1, 1, frame),
    const PixelRect(6, 3, 1, 1, frame), const PixelRect(13, 3, 1, 1, frame),
    const PixelRect(5, 4, 1, 1, frame), const PixelRect(14, 4, 1, 1, frame),
    const PixelRect(4, 5, 1, 1, frame), const PixelRect(15, 5, 1, 1, frame),
    const PixelRect(3, 6, 1, 1, frame), const PixelRect(16, 6, 1, 1, frame),
    const PixelRect(2, 7, 1, 1, frame), const PixelRect(17, 7, 1, 1, frame),
    const PixelRect(1, 8, 1, 1, frame), const PixelRect(18, 8, 1, 1, frame),
    const PixelRect(0, 9, 1, 1, frame), const PixelRect(19, 9, 1, 1, frame),
    const PixelRect(0, 10, 1, 4, frame), const PixelRect(19, 10, 1, 4, frame),
    const PixelRect(0, 14, 20, 1, ground),
    ..._shiftArt(egTreeArt(c), 2, 2),
  ];
}

// 终端揭晓:文本出现或变化时,字符先在乱码里滚动,再自左向右落定。
// 侧栏状态行等等宽文本专用;「减少动态效果」时直接显示最终文本。
class ScrambleText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const ScrambleText({super.key, required this.text, required this.style});

  @override
  State<ScrambleText> createState() => _ScrambleTextState();
}

class _ScrambleTextState extends State<ScrambleText> with SingleTickerProviderStateMixin {
  // 十六进制与标点:等宽字体都有,乱码读起来像终端自检。
  static const _glyphs = '0123456789ABCDEF#/<>=+*';
  late final Random _rnd = Random();
  AnimationController? _ctl;
  String _target = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ctl == null) _reveal(widget.text);
  }

  @override
  void didUpdateWidget(ScrambleText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _reveal(widget.text);
  }

  @override
  void dispose() {
    _ctl?.dispose();
    super.dispose();
  }

  void _reveal(String target) {
    _target = target;
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctl?.value = 1; // 直接落定
      return;
    }
    _ctl ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
    _ctl!.forward(from: 0);
  }

  // t:0→1;左侧 t 比例的字符已落定,其余仍在乱码里滚动,空格保持空格。
  String _compose(double t) {
    final n = _target.length;
    final revealed = (t * n).floor();
    final buf = StringBuffer();
    for (var i = 0; i < n; i++) {
      final ch = _target[i];
      if (ch == ' ') {
        buf.write(' ');
      } else if (i < revealed) {
        buf.write(ch);
      } else {
        buf.write(_glyphs[_rnd.nextInt(_glyphs.length)]);
      }
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = _ctl;
    if (ctl == null) return Text(widget.text, style: widget.style);
    return AnimatedBuilder(
      animation: ctl,
      builder: (context, _) => Text(_compose(ctl.value), style: widget.style),
    );
  }
}
