// 温室设计语言:令牌与主题。
// 原则:暖纸与深常绿构成材质,衬线大字承担标题气质,等宽字体只给真实数据,
// 品牌绿只出现在主行动、选中态与状态指示上;两套主题共用同一套语义名。
import 'package:material_ui/material_ui.dart';

// 双主题令牌:两套主题共用同一套语义名,任何颜色不得写死。
class EgColors {
  final Brightness brightness;
  final Color bg, bg2, panel, panel2, line, line2;
  final Color text, muted, faint;
  final Color acc, accInk, accDim, warn, warnDim, bad, badDim;
  final Color washA, washB, overlay;
  final List<BoxShadow> panelShadow, accShadow, bigShadow;

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
  });

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
}

// 字体角色:同一角色内,拉丁字符与汉字按 fallback 自动分流。
class EgFonts {
  static const display = 'Fraunces';
  static const text = 'Hanken Grotesk';
  static const mono = 'JetBrains Mono';
  static const zhSerif = 'Noto Serif SC';
  static const zhText = 'Noto Sans SC';
}

// 文字角色快捷构造:display / text / mono 各带汉字回退;
// 可变字体以 fontVariations 施加 wght 轴,静态字体忽略该字段。
TextStyle egDisplay(EgColors c, {double? size, Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  return TextStyle(
    fontFamily: EgFonts.display,
    fontFamilyFallback: const [EgFonts.zhSerif],
    fontSize: size,
    color: color ?? c.text,
    fontWeight: weight ?? FontWeight.w600,
    fontVariations: [FontVariation('wght', (weight ?? FontWeight.w600).value.toDouble())],
    height: height ?? 1.25,
    letterSpacing: letterSpacing,
  );
}

TextStyle egText(EgColors c, {double? size, Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  return TextStyle(
    fontFamily: EgFonts.text,
    fontFamilyFallback: const [EgFonts.zhText],
    fontSize: size,
    color: color ?? c.text,
    fontWeight: weight,
    fontVariations: [FontVariation('wght', (weight ?? FontWeight.w400).value.toDouble())],
    height: height ?? 1.65,
    letterSpacing: letterSpacing,
  );
}

TextStyle egMono(EgColors c, {double? size, Color? color, FontWeight? weight, double? height, double? letterSpacing}) {
  return TextStyle(
    fontFamily: EgFonts.mono,
    fontFamilyFallback: const [EgFonts.zhText],
    fontSize: size,
    color: color ?? c.muted,
    fontWeight: weight,
    fontVariations: [FontVariation('wght', (weight ?? FontWeight.w400).value.toDouble())],
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
      radius: const Radius.circular(8),
      crossAxisMargin: 3,
      mainAxisMargin: 4,
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    textTheme: TextTheme(
      bodyMedium: egText(c, size: 13.5),
      bodySmall: egText(c, size: 12.5, color: c.muted),
      labelLarge: egText(c, size: 13, weight: FontWeight.w600),
      titleLarge: egDisplay(c, size: 24),
    ),
    dialogTheme: DialogThemeData(backgroundColor: c.panel, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: c.line2))),
  );
}
