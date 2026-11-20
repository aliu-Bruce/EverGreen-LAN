// 外观参数:默认值、M3 调色、持久化往返。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/core/appearance.dart';
import '../lib/theme.dart';

void main() {
  test('默认外观:主色/字号/圆角均有默认值', () {
    const a = AppAppearance();
    expect(a.seed, AppAppearance.defaultSeed);
    expect(a.typography.sizeScale, 1.0);
    expect(a.radiusScale, 1.0);
  });

  test('调色板随 seed 变化,且字体缩放生效', () {
    const base = AppAppearance();
    final green = base.colorsFor(Brightness.light);
    final blue = AppAppearance(
      seed: const Color(0xFF1E5077),
      typography: const ThemeTypography(sizeScale: 1.2),
      radiusScale: 1.1,
    ).colorsFor(Brightness.light);
    expect(green.acc, isNot(blue.acc));
    expect(blue.sizeScale, 1.2);
    expect(blue.radiusScale, 1.1);
  });

  test('偏好往返:自定义 seed / 字体 / 圆角能恢复', () {
    final a = AppAppearance(
      seed: const Color(0xFFB85B20),
      typography: const ThemeTypography(display: 'Noto Sans SC', displayWeight: 700, sizeScale: 1.1),
      radiusScale: 0.9,
    );
    final again = AppAppearance.fromMap(a.toJson());
    expect(again.seed, const Color(0xFFB85B20));
    expect(again.typography.display, 'Noto Sans SC');
    expect(again.typography.displayWeight, 700);
    expect(again.typography.sizeScale, 1.1);
    expect(again.radiusScale, 0.9);
  });

  test('全无衬线:默认显示与正文同族,衬线字体已下架', () {
    expect(EgFonts.display, EgFonts.text);
    expect(ThemeTypography.allowedFamilies.containsKey('Fraunces'), isFalse);
    expect(ThemeTypography.allowedFamilies.containsKey('Noto Serif SC'), isFalse);
  });

  test('主题令牌插值:端点与中间值都稳定', () {
    final a = const AppAppearance(seed: Color(0xFF2F5D43)).colorsFor(Brightness.light);
    final b = const AppAppearance(seed: Color(0xFF1E5077)).colorsFor(Brightness.light);
    expect(EgColors.lerp(a, b, 0), a);
    expect(EgColors.lerp(a, b, 1), b);
    final mid = EgColors.lerp(a, b, 0.5);
    expect(mid.acc, isNot(a.acc));
    expect(mid.sizeScale, 1.0);
  });

  test('加粗开关:往返持久化,emphasized 字重作用于全局文字角色', () {
    const plain = AppAppearance();
    expect(plain.bold, false);
    final bold = AppAppearance(bold: true);
    expect(AppAppearance.fromMap(bold.toJson()).bold, true);
    final cb = bold.colorsFor(Brightness.light);
    expect(cb.bold, true);
    expect(egText(cb).fontWeight, FontWeight.w700);
    expect(egDisplay(cb).fontWeight, FontWeight.w800);
    final cp = plain.colorsFor(Brightness.light);
    expect(egText(cp).fontWeight, FontWeight.w400);
  });

  test('损坏偏好回退默认,不会抛异常', () {
    final a = AppAppearance.fromMap({'seed': 'red', 'radiusScale': 99});
    expect(a.seed, AppAppearance.defaultSeed);
    expect(a.radiusScale, 1.3); // 损坏的 99 收敛到上限,不抛错
  });

  testWidgets('换色时 EgMotion 逐帧插值而不是瞬切', (tester) async {
    final a = const AppAppearance(seed: Color(0xFF2F5D43)).colorsFor(Brightness.light);
    final b = const AppAppearance(seed: Color(0xFF7B2CBF)).colorsFor(Brightness.light);
    EgColors? seen;
    Widget build(EgColors colors) => EgMotion(
          colors: colors,
          child: Builder(builder: (context) {
            seen = Eg.of(context).c;
            return const SizedBox.shrink();
          }),
        );
    await tester.pumpWidget(build(a));
    expect(seen!.acc, a.acc);
    await tester.pumpWidget(build(b));
    await tester.pump(const Duration(milliseconds: 120));
    expect(seen!.acc, isNot(a.acc));
    expect(seen!.acc, isNot(b.acc));
    await tester.pump(const Duration(milliseconds: 500));
    expect(seen!.acc, b.acc);
  });
}
