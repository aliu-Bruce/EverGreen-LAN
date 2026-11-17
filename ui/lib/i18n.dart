// i18n 引擎:语言包位于 assets/langs/*.json,键为扁平点分名,{x} 为占位符。
// 全部语言随应用启动一次加载;缺键时回退简体中文,再回退键名本身。
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;

class EgLangs {
  static const codes = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'ru', 'es'];
  static const fallback = 'zh-Hans';

  final Map<String, Map<String, String>> _packs = {};
  String cur = fallback;

  String metaName(String code) {
    final p = _packs[code];
    return p?['\$meta.name'] ?? code;
  }

  Future<void> load() async {
    for (final code in codes) {
      try {
        final raw = await rootBundle.loadString('assets/langs/$code.json');
        final obj = jsonDecode(raw) as Map<String, dynamic>;
        final pack = <String, String>{};
        obj.forEach((k, v) {
          if (k == r'$meta') {
            final meta = (v as Map<String, dynamic>).cast<String, String>();
            pack['\$meta.name'] = meta['name'] ?? code;
          } else if (v is String) {
            pack[k] = v;
          }
        });
        _packs[code] = pack;
      } catch (_) {
        // 单个语言包缺失不影响启动:界面按回退语言显示。
      }
    }
  }

  void set(String code) {
    if (_packs.containsKey(code) && codes.contains(code)) cur = code;
  }

  String t(String key, [Map<String, Object?>? vars]) {
    var s = _packs[cur]?[key] ?? _packs[fallback]?[key] ?? key;
    if (vars != null) {
      vars.forEach((name, value) {
        s = s.replaceAll('{$name}', '$value');
      });
    }
    return s;
  }

  // 按系统语言挑默认包;首次启动未记录过语言时使用。
  static String detectSystem() {
    final raw = WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();
    final lower = raw.toLowerCase();
    for (final code in codes) {
      if (lower.startsWith(code.toLowerCase())) return code;
    }
    if (lower.startsWith('zh')) return lower.contains('tw') || lower.contains('hant') ? 'zh-Hant' : 'zh-Hans';
    if (lower.startsWith('en')) return 'en';
    if (lower.startsWith('ja')) return 'ja';
    if (lower.startsWith('ko')) return 'ko';
    if (lower.startsWith('ru')) return 'ru';
    if (lower.startsWith('es')) return 'es';
    return fallback;
  }
}

// 默认名规则:Player- + 系统用户名清洗结果,总长不超 24 字符。
String egDefaultName(String? systemUser) {
  final b = StringBuffer();
  final src = (systemUser ?? '').trim();
  for (final r in src.runes) {
    final c = String.fromCharCode(r);
    final ok = (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || c == '_' || c == '.' || c == '-';
    if (ok) b.write(c);
    if (b.length >= 20) break;
  }
  final clean = b.isEmpty ? '' : b.toString();
  if (clean.isEmpty) return 'Player';
  return ('Player-$clean').length > 24 ? 'Player-$clean'.substring(0, 24) : 'Player-$clean';
}
