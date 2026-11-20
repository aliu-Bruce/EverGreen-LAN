// 温室设计语言:令牌与主题。
// 原则:M3 Expressive 的大色块与药丸形状承担结构,全无衬线字体承担标题气质,
// 等宽字体只给真实数据,品牌色只出现在主行动、选中态与状态指示上;两套主题共用同一套语义名。
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

// 主题的字体/尺寸变量:family/weight 通过 ThemeTypography 验证;sizeScale 统一缩放字号;
// 显示标题与正文都使用无衬线字族,避免衬线在 M3 语境里显得像另一套设计语言。
// radiusScale 统一缩放角半径(>1.25 在可读性边界内自动收紧,详见 autoRadiusTextAdjust)。
class ThemeTypography {
  final String display, text, mono;
  final int displayWeight, textWeight, monoWeight;
  final double sizeScale;

  const ThemeTypography({
    this.display = EgFonts.display,
    this.text = EgFonts.text,
    this.mono = EgFonts.mono,
    this.displayWeight = displayDefault,
    this.textWeight = textDefault,
    this.monoWeight = monoDefault,
    this.sizeScale = 1.0,
  });

  static const displayDefault = 700;
  static const textDefault = 400;
  static const monoDefault = 400;
  // 全无衬线:显示标题与正文共用同一支可变无衬线,汉字统一回退到 Noto Sans SC。
  static const allowedFamilies = {
    'Hanken Grotesk': 'Hanken Grotesk',
    'JetBrains Mono': 'JetBrains Mono',
    'Noto Sans SC': 'Noto Sans SC',
  };
  static const allowedWeights = [300, 400, 500, 600, 700, 800];

  static String normalizeFamily(String s) {
    final t = s.trim();
    return allowedFamilies[t] ?? EgFonts.text;
  }

  static int normalizeWeight(int w) {
    for (final f in allowedWeights) {
      if (f == w) return f;
    }
    return 400;
  }

  static double normalizeSizeScale(double s) {
    if (s < 0.85) s = 0.85;
    if (s > 2.0) s = 2.0;
    return s;
  }

  static double normalizeRadiusScale(double s) {
    if (s < 0.0) s = 0.0;
    if (s > 1.3) s = 1.3;
    return s;
  }

  Map<String, dynamic> toJson() => {
        'display': display,
        'text': text,
        'mono': mono,
        'displayWeight': displayWeight,
        'textWeight': textWeight,
        'monoWeight': monoWeight,
        'sizeScale': sizeScale,
      };

  ThemeTypography copyWith({
    String? display,
    String? text,
    String? mono,
    int? displayWeight,
    int? textWeight,
    int? monoWeight,
    double? sizeScale,
  }) {
    return ThemeTypography(
      display: display ?? this.display,
      text: text ?? this.text,
      mono: mono ?? this.mono,
      displayWeight: displayWeight ?? this.displayWeight,
      textWeight: textWeight ?? this.textWeight,
      monoWeight: monoWeight ?? this.monoWeight,
      sizeScale: sizeScale ?? this.sizeScale,
    );
  }
}

// 给定角半径(px)时,尽量让它在 1.25–1.3 区间:角过大会吃掉文字,通过缩小文字缓解。
double autoRadiusTextAdjust(double px, double radiusScale) {
  if (radiusScale > 1.25) {
    final reduce = (radiusScale - 1.25).clamp(0.0, 0.2) * 0.2;
    return px * (1 - reduce);
  }
  return px;
}

// 双主题令牌:两套主题共用同一套语义名,任何颜色不得写死。
class EgColors {
  final Brightness brightness;
  final Color bg, bg2, panel, panel2, line, line2;
  final Color text, muted, faint;
  final Color acc, accInk, accDim, warn, warnDim, bad, badDim;
  final Color washA, washB, overlay;
  final List<BoxShadow> panelShadow, accShadow, bigShadow;
  // 主题字体:display/text/mono 三个角色,以及 display 的粗细。
  final String displayFamily, textFamily, monoFamily;
  final int displayWeight, textWeight, monoWeight;
  // 字号全局缩放,默认 1.0 不变;超过 2.0 拒绝。
  final double sizeScale;
  // 角半径全局缩放,默认 1.0;超过 1.25 在保持界面可读性前提下自动收紧。
  final double radiusScale;
  // 全局加粗开关:把各文字角色的字重提升到 M3 emphasized 档位。
  final bool bold;

  const EgColors({
    required this.brightness,
    required this.bg,
    required this.bg2,
    required this.panel,
    required this.panel2,
    required this.line,
    required this.line2,
    required this.text,
    required this.muted,
    required this.faint,
    required this.acc,
    required this.accInk,
    required this.accDim,
    required this.warn,
    required this.warnDim,
    required this.bad,
    required this.badDim,
    required this.washA,
    required this.washB,
    required this.overlay,
    required this.panelShadow,
    required this.accShadow,
    required this.bigShadow,
    this.displayFamily = EgFonts.display,
    this.displayWeight = ThemeTypography.displayDefault,
    this.textFamily = EgFonts.text,
    this.textWeight = ThemeTypography.textDefault,
    this.monoFamily = EgFonts.mono,
    this.monoWeight = ThemeTypography.monoDefault,
    this.sizeScale = 1.0,
    this.radiusScale = 1.0,
    this.bold = false,
  });

  // 把字体/缩放字段应用到新 EgColors(颜色保持)。
  EgColors withTypography({
    String? displayFamily,
    int? displayWeight,
    String? textFamily,
    int? textWeight,
    String? monoFamily,
    int? monoWeight,
    double? sizeScale,
    double? radiusScale,
    bool? bold,
  }) {
    return EgColors(
      brightness: brightness,
      bg: bg,
      bg2: bg2,
      panel: panel,
      panel2: panel2,
      line: line,
      line2: line2,
      text: text,
      muted: muted,
      faint: faint,
      acc: acc,
      accInk: accInk,
      accDim: accDim,
      warn: warn,
      warnDim: warnDim,
      bad: bad,
      badDim: badDim,
      washA: washA,
      washB: washB,
      overlay: overlay,
      panelShadow: panelShadow,
      accShadow: accShadow,
      bigShadow: bigShadow,
      displayFamily: displayFamily ?? this.displayFamily,
      displayWeight: displayWeight ?? this.displayWeight,
      textFamily: textFamily ?? this.textFamily,
      textWeight: textWeight ?? this.textWeight,
      monoFamily: monoFamily ?? this.monoFamily,
      monoWeight: monoWeight ?? this.monoWeight,
      sizeScale: sizeScale ?? this.sizeScale,
      radiusScale: radiusScale ?? this.radiusScale,
      bold: bold ?? this.bold,
    );
  }

  static const dark = EgColors(
    brightness: Brightness.dark,
    bg: Color(0xFF101913),
    bg2: Color(0xFF0C130E),
    panel: Color(0xFF18231C),
    panel2: Color(0xFF202D25),
    line: Color(0xFF2A3A30),
    line2: Color(0xFF3D5145),
    text: Color(0xFFEDE9DC),
    muted: Color(0xFFA5B1A1),
    faint: Color(0xFF71806F),
    acc: Color(0xFFC7E28B),
    accInk: Color(0xFF16240F),
    accDim: Color(0xFF2B3D24),
    warn: Color(0xFFD9A968),
    warnDim: Color(0xFF43301B),
    bad: Color(0xFFE08B76),
    badDim: Color(0xFF46231B),
    washA: Color(0x1A96C896),
    washB: Color(0x0FD2B478),
    overlay: Color(0x8C060A07),
    panelShadow: [],
    accShadow: [BoxShadow(color: Color(0x4D000000), blurRadius: 20, offset: Offset(0, 8))],
    bigShadow: [BoxShadow(color: Color(0x80000000), blurRadius: 60, offset: Offset(0, 24))],
  );

  static const light = EgColors(
    brightness: Brightness.light,
    bg: Color(0xFFF2EDE2),
    bg2: Color(0xFFEBE4D4),
    panel: Color(0xFFFBF8F0),
    panel2: Color(0xFFF1EBDD),
    line: Color(0xFFE5DCC8),
    line2: Color(0xFFCDC2A7),
    text: Color(0xFF272E26),
    muted: Color(0xFF5D6455),
    faint: Color(0xFF9B9E8C),
    acc: Color(0xFF2F5D43),
    accInk: Color(0xFFF7F4EA),
    accDim: Color(0xFFE1EBDA),
    warn: Color(0xFF8A5E1E),
    warnDim: Color(0xFFF4E8D2),
    bad: Color(0xFFA8452F),
    badDim: Color(0xFFF6E2DC),
    washA: Color(0x143F5E4A),
    washB: Color(0x1ABF9E69),
    overlay: Color(0x6138301E),
    panelShadow: [BoxShadow(color: Color(0x0F40341C), blurRadius: 2, offset: Offset(0, 1))],
    accShadow: [BoxShadow(color: Color(0x402F5D43), blurRadius: 20, offset: Offset(0, 8))],
    bigShadow: [
      BoxShadow(color: Color(0x2E40341C), blurRadius: 60, offset: Offset(0, 24)),
      BoxShadow(color: Color(0x1440341C), blurRadius: 6, offset: Offset(0, 2)),
    ],
  );

  // 值相等:主题令牌每帧被插值重建,只有内容真正变化时才触发整树重建。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EgColors &&
        other.brightness == brightness &&
        other.bg == bg &&
        other.bg2 == bg2 &&
        other.panel == panel &&
        other.panel2 == panel2 &&
        other.line == line &&
        other.line2 == line2 &&
        other.text == text &&
        other.muted == muted &&
        other.faint == faint &&
        other.acc == acc &&
        other.accInk == accInk &&
        other.accDim == accDim &&
        other.warn == warn &&
        other.warnDim == warnDim &&
        other.bad == bad &&
        other.badDim == badDim &&
        other.washA == washA &&
        other.washB == washB &&
        other.overlay == overlay &&
        listEquals(other.panelShadow, panelShadow) &&
        listEquals(other.accShadow, accShadow) &&
        listEquals(other.bigShadow, bigShadow) &&
        other.displayFamily == displayFamily &&
        other.textFamily == textFamily &&
        other.monoFamily == monoFamily &&
        other.displayWeight == displayWeight &&
        other.textWeight == textWeight &&
        other.monoWeight == monoWeight &&
        other.sizeScale == sizeScale &&
        other.radiusScale == radiusScale &&
        other.bold == bold;
  }

  @override
  int get hashCode => Object.hashAll([
        brightness,
        bg,
        bg2,
        panel,
        panel2,
        line,
        line2,
        text,
        muted,
        faint,
        acc,
        accInk,
        accDim,
        warn,
        warnDim,
        bad,
        badDim,
        washA,
        washB,
        overlay,
        displayFamily,
        textFamily,
        monoFamily,
        displayWeight,
        textWeight,
        monoWeight,
        sizeScale,
        radiusScale,
        bold,
      ]);

  // 令牌插值:主色/明暗切换时让所有表面与文字颜色连续过渡。
  static EgColors lerp(EgColors a, EgColors b, double t) {
    if (identical(a, b) || t <= 0) return a;
    if (t >= 1) return b;
    Color mix(Color x, Color y) => Color.lerp(x, y, t)!;
    return EgColors(
      brightness: t < 0.5 ? a.brightness : b.brightness,
      bg: mix(a.bg, b.bg),
      bg2: mix(a.bg2, b.bg2),
      panel: mix(a.panel, b.panel),
      panel2: mix(a.panel2, b.panel2),
      line: mix(a.line, b.line),
      line2: mix(a.line2, b.line2),
      text: mix(a.text, b.text),
      muted: mix(a.muted, b.muted),
      faint: mix(a.faint, b.faint),
      acc: mix(a.acc, b.acc),
      accInk: mix(a.accInk, b.accInk),
      accDim: mix(a.accDim, b.accDim),
      warn: mix(a.warn, b.warn),
      warnDim: mix(a.warnDim, b.warnDim),
      bad: mix(a.bad, b.bad),
      badDim: mix(a.badDim, b.badDim),
      washA: mix(a.washA, b.washA),
      washB: mix(a.washB, b.washB),
      overlay: mix(a.overlay, b.overlay),
      panelShadow: t < 0.5 ? a.panelShadow : b.panelShadow,
      accShadow: t < 0.5 ? a.accShadow : b.accShadow,
      bigShadow: t < 0.5 ? a.bigShadow : b.bigShadow,
      displayFamily: t < 0.5 ? a.displayFamily : b.displayFamily,
      displayWeight: t < 0.5 ? a.displayWeight : b.displayWeight,
      textFamily: t < 0.5 ? a.textFamily : b.textFamily,
      textWeight: t < 0.5 ? a.textWeight : b.textWeight,
      monoFamily: t < 0.5 ? a.monoFamily : b.monoFamily,
      monoWeight: t < 0.5 ? a.monoWeight : b.monoWeight,
      sizeScale: a.sizeScale + (b.sizeScale - a.sizeScale) * t,
      radiusScale: a.radiusScale + (b.radiusScale - a.radiusScale) * t,
      bold: t < 0.5 ? a.bold : b.bold,
    );
  }
}

// 主题过渡:M3 emphasized 缓动下把旧令牌平滑插值到新令牌。
class EgMotion extends StatefulWidget {
  final EgColors colors;
  final Widget child;
  const EgMotion({super.key, required this.colors, required this.child});

  @override
  State<EgMotion> createState() => _EgMotionState();
}

class _EgMotionState extends State<EgMotion> with SingleTickerProviderStateMixin {
  // M3 emphasized 缓动,略长于系统主题动画,让选色有"落定"的过程。
  static const _ease = Cubic(0.2, 0, 0, 1);
  static const _duration = Duration(milliseconds: 420);

  late EgColors _from = widget.colors;
  late EgColors _to = widget.colors;
  late final AnimationController _ctl =
      AnimationController(vsync: this, duration: _duration, value: 1);

  EgColors get _current => EgColors.lerp(_from, _to, _ease.transform(_ctl.value));

  @override
  void didUpdateWidget(EgMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.colors == _to) return;
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _from = _current;
    _to = widget.colors;
    if (reduced) {
      _ctl.value = 1;
    } else {
      _ctl.forward(from: 0);
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
      builder: (context, _) => Eg(c: _current, child: widget.child),
    );
  }
}

// 全局界面字号倍率:默认主题下的可读尺寸,主题 sizeScale 在此之上叠加。
const double kUiFontScale = 1.16;

// 字体角色:同一角色内,拉丁字符与汉字按 fallback 自动分流。
class EgFonts {
  static const display = 'Hanken Grotesk';
  static const text = 'Hanken Grotesk';
  static const mono = 'JetBrains Mono';
  static const zhText = 'Noto Sans SC';
}

// M3 Expressive emphasized 字重:正文 400→700、显示 700→800,其余就近升档。
FontWeight _egEmphasize(FontWeight w, bool bold) {
  if (!bold) return w;
  return switch (w.value) {
    <= 300 => FontWeight.w600,
    <= 500 => FontWeight.w700,
    <= 700 => FontWeight.w800,
    _ => FontWeight.w900,
  };
}

// 文字角色快捷构造:display / text / mono 各带汉字回退;
// 可变字体以 fontVariations 施加 wght 轴,静态字体忽略该字段。
TextStyle egDisplay(EgColors c, {double? size, Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  final w = _egEmphasize(weight ?? FontWeight.values.firstWhere((f) => f.value == c.displayWeight, orElse: () => FontWeight.w600), c.bold);
  final s = size == null ? null : autoRadiusTextAdjust(size * c.sizeScale * kUiFontScale, c.radiusScale);
  return TextStyle(
    fontFamily: c.displayFamily,
    fontFamilyFallback: const [EgFonts.zhText],
    fontSize: s,
    color: color ?? c.text,
    fontWeight: w,
    fontVariations: [FontVariation('wght', w.value.toDouble())],
    height: height ?? 1.25,
    letterSpacing: letterSpacing,
  );
}

TextStyle egText(EgColors c, {double? size, Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  final w = _egEmphasize(weight ?? FontWeight.values.firstWhere((f) => f.value == c.textWeight, orElse: () => FontWeight.w400), c.bold);
  final s = size == null ? null : autoRadiusTextAdjust(size * c.sizeScale * kUiFontScale, c.radiusScale);
  return TextStyle(
    fontFamily: c.textFamily,
    fontFamilyFallback: const [EgFonts.zhText],
    fontSize: s,
    color: color ?? c.text,
    fontWeight: w,
    fontVariations: [FontVariation('wght', w.value.toDouble())],
    height: height ?? 1.65,
    letterSpacing: letterSpacing,
  );
}

TextStyle egMono(EgColors c, {double? size, Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  final w = _egEmphasize(weight ?? FontWeight.values.firstWhere((f) => f.value == c.monoWeight, orElse: () => FontWeight.w400), c.bold);
  final s = size == null ? null : autoRadiusTextAdjust(size * c.sizeScale * kUiFontScale, c.radiusScale);
  return TextStyle(
    fontFamily: c.monoFamily,
    fontFamilyFallback: const [EgFonts.zhText],
    fontSize: s,
    color: color ?? c.muted,
    fontWeight: w,
    fontVariations: [FontVariation('wght', w.value.toDouble())],
    height: height ?? 1.5,
    letterSpacing: letterSpacing,
  );
}

// 氛围光层:radial 两团,位置与原型一致(右上偏上、左下偏下)。
class EgMist extends StatelessWidget {
  const EgMist({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            right: -220,
            top: -260,
            child: Container(
              width: 1100,
              height: 720,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [c.washA, c.washA.withValues(alpha: 0)],
                  stops: const [0, 0.62],
                ),
              ),
            ),
          ),
          Positioned(
            left: -260,
            bottom: -300,
            child: Container(
              width: 900,
              height: 640,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [c.washB, c.washB.withValues(alpha: 0)],
                  stops: const [0, 0.58],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 主题皮肤:把令牌沿树下发,页面用 Eg.of(context).c 取色。
class Eg extends InheritedWidget {
  final EgColors c;
  const Eg({super.key, required this.c, required super.child});

  static Eg of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<Eg>()!;

  @override
  bool updateShouldNotify(Eg oldWidget) => c != oldWidget.c;
}

// ThemeData:配色与选区、滚动条等系统件贴合温室令牌。
ThemeData egTheme(EgColors c) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme(
      brightness: c.brightness,
      primary: c.acc,
      onPrimary: c.accInk,
      secondary: c.acc,
      onSecondary: c.accInk,
      error: c.bad,
      onError: Colors.white,
      surface: c.panel,
      onSurface: c.text,
      surfaceContainerHighest: c.panel2,
      surfaceContainer: c.panel,
      surfaceContainerLow: c.panel,
      surfaceContainerLowest: c.bg,
      onSurfaceVariant: c.muted,
      outline: c.line2,
      outlineVariant: c.line,
      surfaceTint: Colors.transparent,
    ),
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashColor: c.text.withValues(alpha: 0.12),
    highlightColor: c.text.withValues(alpha: 0.06),
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.acc,
      selectionColor: c.acc.withValues(alpha: 0.35),
      selectionHandleColor: c.acc,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(4),
      thumbColor: WidgetStateProperty.all(c.line2),
      radius: Radius.circular(8 * c.radiusScale),
      crossAxisMargin: 3,
      mainAxisMargin: 4,
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    // M3 Expressive:滑块轨道与拇指更圆润,选中色用 acc 角色。
    sliderTheme: SliderThemeData(
      activeTrackColor: c.acc,
      inactiveTrackColor: c.line2.withValues(alpha: 0.35),
      thumbColor: c.acc,
      overlayColor: c.acc.withValues(alpha: 0.18),
      trackHeight: 8,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
    ),
    // M3 Expressive 开关:粗轨道 + 大拇指,选中态用主色角色。
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.acc : c.line2.withValues(alpha: 0.5)),
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accInk : c.panel),
      overlayColor: WidgetStateProperty.all(c.acc.withValues(alpha: 0.16)),
    ),
    textTheme: TextTheme(
      bodyMedium: egText(c, size: 13.5),
      bodySmall: egText(c, size: 12.5, color: c.muted),
      labelLarge: egText(c, size: 13, weight: FontWeight.w600),
      titleLarge: egDisplay(c, size: 24),
    ),
    dialogTheme: DialogThemeData(backgroundColor: c.panel, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32 * c.radiusScale), side: BorderSide(color: c.line2))),
  );
}
