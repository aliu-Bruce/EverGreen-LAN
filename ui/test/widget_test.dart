// 纯逻辑单测:默认名规则。构建冒烟由 flutter build windows 负责。
import 'package:flutter_test/flutter_test.dart';

import 'package:eglan_ui/i18n.dart';

void main() {
  test('默认名:Player- + 清洗后的用户名', () {
    expect(egDefaultName('Jinlo'), 'Player-Jinlo');
  });

  test('默认名:剔除不安全字符', () {
    expect(egDefaultName('jin/lo 组'), 'Player-jinlo');
  });

  test('默认名:空用户名回退 Player', () {
    expect(egDefaultName(''), 'Player');
    expect(egDefaultName(null), 'Player');
  });

  test('默认名:总长不超 24', () {
    final n = egDefaultName('a' * 40);
    expect(n.length, lessThanOrEqualTo(24));
    expect(n.startsWith('Player-'), isTrue);
  });
}
