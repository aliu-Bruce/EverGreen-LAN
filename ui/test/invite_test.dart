import 'package:flutter_test/flutter_test.dart';

import 'package:eglan_ui/core/invite.dart';

void main() {
  test('邀请:构造后能解析出房间码与地址', () {
    final link = EgInvite.build('k7q2 m9xd', '203.0.113.5:62000');
    expect(link, 'eglan://join/K7Q2M9XD?peer=203.0.113.5%3A62000');

    final invite = EgInvite.parse(link);
    expect(invite, isNotNull);
    expect(invite!.code, 'K7Q2M9XD');
    expect(invite.peer, '203.0.113.5:62000');
  });

  test('邀请:从聊天文本中提取,忽略前后内容与标点', () {
    final invite = EgInvite.parse(
      '加入我的 EGLAN 房间 K7Q2 M9XD:\n'
      'eglan://join/k7q2m9xd?peer=192.168.1.88:47777。\n'
      '等你。',
    );
    expect(invite, isNotNull);
    expect(invite!.code, 'K7Q2M9XD');
    expect(invite.peer, '192.168.1.88:47777');
  });

  test('邀请:非邀请文本返回 null', () {
    expect(EgInvite.parse('K7Q2M9XD'), isNull);
    expect(EgInvite.parse('https://example.com/join/K7Q2M9XD'), isNull);
    expect(EgInvite.parse('eglan://join/1234?peer=1.2.3.4:5'), isNull);
  });

  test('邀请:地址缺端口时仍保留房间码', () {
    final invite = EgInvite.parse('eglan://join/K7Q2M9XD?peer=192.168.1.88');
    expect(invite, isNotNull);
    expect(invite!.code, 'K7Q2M9XD');
    expect(invite.peer, isNull);
  });
}
