// 外观参数:主色(seed)+字体/字号+圆角。直接由设置页控件编辑,没有主题包/预设概念。
// 颜色由 Material You(ColorScheme.fromSeed)从主色自动推出浅/深两套。
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

class AppAppearance {
  // 与内置主色一致的默认种子色。
  static const defaultSeed = Color(0xFF2F5D43);

  final Color seed;
  final ThemeTypography typography;
  final double radiusScale;
  // 全局加粗:开启后所有文字角色采用 M3 Expressive 的 emphasized 字重。
  final bool bold;

  const AppAppearance({
    this.seed = defaultSeed,
    this.typography = const ThemeTypography(),
    this.radiusScale = 1.0,
    this.bold = false,
  });

  AppAppearance copyWith({Color? seed, ThemeTypography? typography, double? radiusScale, bool? bold}) {
    return AppAppearance(
      seed: seed ?? this.seed,
      typography: typography ?? this.typography,
      radiusScale: (radiusScale ?? this.radiusScale).clamp(0.0, 1.3).toDouble(),
      bold: bold ?? this.bold,
    );
  }

  // 彩虹预设色块:红/橙/黄/绿/青/蓝/紫,高饱和且不过暗。
  static const rainbowSeeds = <Color>[
    Color(0xFFD32F2F), // 红
    Color(0xFFEF6C00), // 橙
    Color(0xFFD9A100), // 黄
    Color(0xFF2E9E4F), // 绿
    Color(0xFF00A5A5), // 青
    Color(0xFF2F5FE0), // 蓝
    Color(0xFF7B2CBF), // 紫
  ];

  // 由 seed 推出两套 M3 调色板,再套用字体/字号/圆角。
  // fidelity:主色尽量保留用户选定的色相与饱和度,M3 Expressive 的容器色更明确。
  EgColors colorsFor(Brightness brightness) {
    final cs = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    final base = brightness == Brightness.dark ? EgColors.dark : EgColors.light;
    Color pick(String key, Color fallback) => switch (key) {
          'bg' => cs.surface,
          'panel' => cs.surfaceContainer,
          'panel2' => cs.surfaceContainerLowest,
          'line' => cs.outlineVariant,
          'line2' => cs.outline,
          'text' => cs.onSurface,
          'muted' => cs.onSurfaceVariant,
          'faint' => cs.inverseSurface,
          'acc' => cs.primary,
          'accInk' => cs.onPrimary,
          // fidelity 变体下 primaryContainer 会等于深色 seed;这里改为主色薄涂,
          // 保持"容器色 + 主色文字"的可读组合,也更贴近 Expressive 的柔和色面。
          'accDim' => Color.alphaBlend(
            cs.primary.withValues(alpha: brightness == Brightness.light ? 0.16 : 0.26),
            brightness == Brightness.light ? cs.surface : cs.surfaceContainer,
          ),
          'warn' => cs.secondary,
          'warnDim' => cs.secondaryContainer,
          'bad' => cs.error,
          'badDim' => cs.errorContainer,
          'washA' => cs.primary.withAlpha(0x1A),
          'washB' => cs.tertiary.withAlpha(0x0F),
          'overlay' => cs.inverseSurface.withAlpha(0x8C),
          _ => fallback,
        };
    final c = EgColors(
      brightness: base.brightness,
      bg: pick('bg', base.bg),
      bg2: pick('bg2', base.bg),
      panel: pick('panel', base.panel),
      panel2: pick('panel2', base.panel2),
      line: pick('line', base.line),
      line2: pick('line2', base.line2),
      text: pick('text', base.text),
      muted: pick('muted', base.muted),
      faint: pick('faint', base.faint),
      acc: pick('acc', base.acc),
      accInk: pick('accInk', base.accInk),
      accDim: pick('accDim', base.accDim),
      warn: pick('warn', base.warn),
      warnDim: pick('warnDim', base.warnDim),
      bad: pick('bad', base.bad),
      badDim: pick('badDim', base.badDim),
      washA: pick('washA', base.washA),
      washB: pick('washB', base.washB),
      overlay: pick('overlay', base.overlay),
      panelShadow: base.panelShadow,
      accShadow: base.accShadow,
      bigShadow: base.bigShadow,
    );
    return c.withTypography(
      displayFamily: typography.display,
      displayWeight: typography.displayWeight,
      textFamily: typography.text,
      textWeight: typography.textWeight,
      monoFamily: typography.mono,
      sizeScale: typography.sizeScale,
      radiusScale: radiusScale,
      bold: bold,
    );
  }

  Map<String, dynamic> toJson() => {
        'seed': '#' + (seed.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase(),
        'typography': typography.toJson(),
        'radiusScale': radiusScale,
        'bold': bold,
      };

  static AppAppearance fromMap(Object? obj) {
    if (obj is! Map) return const AppAppearance();
    try {
      final seedObj = obj['seed'];
      Color seed = defaultSeed;
      if (seedObj is String && seedObj.startsWith('#') && seedObj.length == 7) {
        final v = int.tryParse(seedObj.substring(1), radix: 16);
        if (v != null) seed = Color(0xFF000000 | v);
      }
      final t = obj['typography'];
      ThemeTypography typography = const ThemeTypography();
      if (t is Map) {
        final fam = (String key, String def) {
          final v = t[key];
          return v is String && ThemeTypography.allowedFamilies.containsKey(v) ? v : def;
        };
        final weight = (String key, int def) {
          final v = t[key];
          return v is int && ThemeTypography.allowedWeights.contains(v) ? v : def;
        };
        final size = t['sizeScale'];
        typography = ThemeTypography(
          display: fam('display', EgFonts.display),
          text: fam('text', EgFonts.text),
          mono: fam('mono', EgFonts.mono),
          displayWeight: weight('displayWeight', ThemeTypography.displayDefault),
          textWeight: weight('textWeight', 400),
          monoWeight: weight('monoWeight', 400),
          sizeScale: size is num && size >= 0.85 && size <= 2.0 ? size.toDouble() : 1.0,
        );
      }
      final r = obj['radiusScale'];
      final b = obj['bold'];
      return AppAppearance(
        seed: seed,
        typography: typography,
        radiusScale: r is num ? r.clamp(0.0, 1.3).toDouble() : 1.0,
        bold: b is bool ? b : false,
      );
    } catch (_) {
      return const AppAppearance();
    }
  }

  // 偏好里保存的 JSON 文本(便于调试/迁移,不作为导入格式暴露给用户)。
  @override
  String toString() => jsonEncode(toJson());
}
