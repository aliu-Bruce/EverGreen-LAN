// 语言包校验:七份键集一致、占位符一致,且根目录副本与界面实际加载的副本相同。
// 根目录副本供 HTML 原型使用;两处一旦分叉,界面会出现键名而不是文案。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const codes = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'ru', 'es'];

Map<String, String> load(String path) {
  final obj = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final out = <String, String>{};
  obj.forEach((k, v) {
    if (k == r'$meta') {
      final meta = (v as Map).cast<String, dynamic>();
      out[r'$meta.tag'] = (meta['tag'] as String?) ?? '';
      out[r'$meta.name'] = (meta['name'] as String?) ?? '';
    } else if (v is String) {
      out[k] = v;
    }
  });
  return out;
}

Set<String> placeholders(String text) =>
    RegExp(r'\{(\w+)\}').allMatches(text).map((m) => m.group(1)!).toSet();

void main() {
  test('语言包:七份键集与占位符一致,根目录副本同步', () {
    final packs = {for (final code in codes) code: load('assets/langs/$code.json')};
    Set<String> keysOf(String code) =>
        packs[code]!.keys.where((k) => !k.startsWith(r'$meta')).toSet();
    final base = keysOf('zh-Hans');

    for (final code in codes) {
      final keys = keysOf(code);
      expect(keys.difference(base), isEmpty, reason: '$code 存在多余键');
      expect(base.difference(keys), isEmpty, reason: '$code 缺少键');
      expect(packs[code]![r'$meta.tag'], code, reason: '$code 的 meta.tag 不符');
      expect(packs[code]![r'$meta.name'], isNotEmpty, reason: '$code 缺少语言自称');

      for (final key in keys) {
        final text = packs[code]![key]!;
        expect(text, isNotEmpty, reason: '$code.$key 为空');
        expect(text, isNot(key), reason: '$code.$key 尚未翻译');
        expect(
          placeholders(text),
          placeholders(packs['zh-Hans']![key]!),
          reason: '$code.$key 的占位符与简体中文不一致',
        );
      }

      expect(
        load('../assets/langs/$code.json'),
        packs[code],
        reason: '$code 的根目录副本与 ui/assets 不一致',
      );
    }
  });

  test('语言包:代码里用到的文案键都存在', () {
    final pack = load('assets/langs/zh-Hans.json');
    final used = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      for (final match in RegExp(r"(?:langs\.)?t\('([^']+)'").allMatches(text)) {
        final key = match.group(1)!;
        // 只收点分键,排除 t('—') 这类占位文案与动态拼接。
        if (RegExp(r'^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+$').hasMatch(key)) {
          used.add(key);
        }
      }
    }
    final missing = used.where((key) => !pack.containsKey(key)).toList()..sort();
    expect(missing, isEmpty, reason: '这些键会直接显示在界面上: ${missing.join(', ')}');
  });
}
