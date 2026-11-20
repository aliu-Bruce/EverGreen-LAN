// 二维码闭环:邀请链接 → PNG → 解码,必须还原原文。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/qr.dart';

void main() {
  test('矩阵编码:链接生成方阵且黑白都有', () {
    final m = encodeQr('eglan://join/ABCD1234?peer=192.168.1.10:47777');
    expect(m, isNotNull);
    expect(m!.size, greaterThan(20));
    expect(m.dark.any((v) => v == 1), isTrue);
    expect(m.dark.any((v) => v == 0), isTrue);
  });

  test('PNG 往返:短邀请链接能解码还原', () {
    const link = 'eglan://join/ABCD1234?peer=10.66.7.1:47777';
    final png = renderQrPng(link);
    expect(png, isNotNull);
    expect(decodeQr(png!), link);
  });

  test('PNG 往返:长地址(IPv6 风格)也能还原', () {
    const link = 'eglan://join/ZZZZ9999?peer=2001:db8::1:47777';
    final png = renderQrPng(link);
    expect(png, isNotNull);
    expect(decodeQr(png!), link);
  });

  test('非二维码图片解码返回 null 而不是抛异常', () {
    // 一张纯白小图
    final png = renderQrPng('x');
    expect(png, isNotNull);
    expect(decodeQr(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });
}
