// 下拉菜单:贴近屏幕底部时应可滚动且向上展开。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/theme.dart';
import '../lib/widgets/eg.dart';

void main() {
  testWidgets('下拉菜单打开后有滚动容器', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Eg(
          c: EgColors.light,
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 300,
                height: 80,
                child: EgDropdown<int>(
                  items: [for (var i = 0; i < 12; i++) (i, '语言 $i')],
                  value: 0,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(EgDropdown<int>));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });
}
