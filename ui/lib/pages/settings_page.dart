// 设置页:外观(纵向编辑主色/字体/字号/圆角)+身份、权限、网络、关于。
import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/appearance.dart';
import '../core/prefs.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class _HsvColorS {
  final double h, s, v;
  const _HsvColorS({required this.h, required this.s, required this.v});
}

// M3 Expressive 风格色块:选中态用描边与柔和投影强调,按下有回弹感(近似 spring)。
class _RainbowChip extends StatefulWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _RainbowChip({required this.color, required this.selected, required this.onTap});

  @override
  State<_RainbowChip> createState() => _RainbowChipState();
}

class _RainbowChipState extends State<_RainbowChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: AnimatedScale(
        scale: _pressed ? 0.86 : (widget.selected ? 1.12 : 1.0),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.selected ? 14 : 30),
              color: widget.color,
              border: Border.all(color: widget.selected ? c.acc : c.line2, width: widget.selected ? 3 : 1),
              boxShadow: widget.selected
                  ? [BoxShadow(color: widget.color.withValues(alpha: 0.45), blurRadius: 12, spreadRadius: 1)]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _mtu = TextEditingController();
  final TextEditingController _stun = TextEditingController();
  final TextEditingController _seed = TextEditingController();
  final TextEditingController _sizeScale = TextEditingController();
  final TextEditingController _radiusScale = TextEditingController();

  String _displayFamily = EgFonts.display;
  String _textFamily = EgFonts.text;
  String _monoFamily = EgFonts.mono;
  String? _seedError;

  bool _restarting = false;
  bool _stunTesting = false;
  String? _stunError;
  String? _stunResult;

  @override
  void initState() {
    super.initState();
    final app = AppState.of(context);
    _name.text = app.prefs.name;
    _port.text = '${app.prefs.port}';
    _mtu.text = '${app.prefs.mtu}';
    _stun.text = app.prefs.stun;
    _syncAppearance(app.appearance);
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _port,
      _mtu,
      _stun,
      _seed,
      _sizeScale,
      _radiusScale,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncAppearance(AppAppearance a) {
    _seed.text = hexOf(a.seed);
    _sizeScale.text = '${a.typography.sizeScale}';
    _radiusScale.text = '${a.radiusScale}';
    _displayFamily = a.typography.display;
    _textFamily = a.typography.text;
    _monoFamily = a.typography.mono;
  }

  void _update(AppState app, {Color? seed, String? display, String? text, String? mono, bool? bold, double? size, double? radius}) {
    final a = app.appearance;
    final newSize = size == null ? a.typography.sizeScale : size.clamp(0.85, 2.0);
    final newRadius = radius == null ? a.radiusScale : radius.clamp(0.0, 1.3);
    _sizeScale.text = '$newSize';
    _radiusScale.text = '$newRadius';
    app.setAppearance(a.copyWith(
      seed: seed,
      typography: ThemeTypography(
        display: display ?? _displayFamily,
        text: text ?? _textFamily,
        mono: mono ?? _monoFamily,
        displayWeight: a.typography.displayWeight,
        textWeight: a.typography.textWeight,
        monoWeight: a.typography.monoWeight,
        sizeScale: newSize,
      ),
      radiusScale: newRadius,
      bold: bold ?? a.bold,
    ));
  }

  void _onSeedChanged(AppState app, String raw) {
    final color = parseHex(raw.trim());
    setState(() => _seedError = color == null && raw.trim().isNotEmpty ? 'seed' : null);
    if (color != null) {
      app.setAppearance(app.appearance.copyWith(seed: color));
    }
  }

  // 调色盘或预设选色:主色与 16 进制输入同步更新。
  void _setSeed(AppState app, Color color) {
    final hx = hexOf(color);
    if (_seed.text != hx) _seed.text = hx;
    if (_seedError != null) setState(() => _seedError = null);
    if (app.appearance.seed == color) return;
    app.setAppearance(app.appearance.copyWith(seed: color));
  }

  void _resetAll(AppState app) {
    app.resetAppearance();
    app.setThemeMode(EgThemeMode.system);
    app.setNavMode(EgNavMode.side);
    _syncAppearance(app.appearance);
    setState(() => _seedError = null);
  }

  void _commitNet(AppState app) {
    final port = int.tryParse(_port.text.trim());
    final mtu = int.tryParse(_mtu.text.trim());
    app.setNet(
      port == null || port < 1 || port > 65535 ? app.prefs.port : port,
      mtu == null || mtu < 576 || mtu > 9000 ? app.prefs.mtu : mtu,
    );
    _port.text = '${app.prefs.port}';
    _mtu.text = '${app.prefs.mtu}';
  }

  Future<void> _testStun(AppState app) async {
    if (_stunTesting) return;
    final candidate = _stun.text.trim().isEmpty ? Prefs.defaultStun : _stun.text.trim();
    setState(() {
      _stunTesting = true;
      _stunError = null;
      _stunResult = null;
    });
    try {
      final result = await app.testStun(candidate);
      if (!mounted) return;
      app.setStun(result.server);
      setState(() {
        _stun.text = result.server;
        _stunResult = app.langs.t('set.stunResult', {'addr': result.addr});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _stunError = '${app.langs.t('set.stunFail')}$e');
    } finally {
      if (mounted) setState(() => _stunTesting = false);
    }
  }

  void _resetStun(AppState app) {
    if (_stunTesting) return;
    setState(() {
      _stun.text = Prefs.defaultStun;
      _stunError = null;
      _stunResult = app.langs.t('set.stunRestored');
    });
    app.setStun(Prefs.defaultStun);
  }

  Future<void> _restartAsAdmin(AppState app) async {
    if (_restarting) return;
    setState(() => _restarting = true);
    final err = await app.elevateCore();
    if (!mounted) return;
    setState(() => _restarting = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(err ?? app.langs.t('set.permDone')),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: err == null ? 3 : 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;

    return StaggerIn(
      spacing: 16,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(app.langs.t('set.title'), style: egDisplay(c, size: 34, weight: FontWeight.w800, letterSpacing: -0.03, height: 1.1)),
            const SizedBox(width: 14),
            Container(width: 46, height: 8, decoration: BoxDecoration(color: c.acc, borderRadius: BorderRadius.circular(100))),
          ],
        ),

        // 外观:纵向卡片式,所有可自定义项摊开
        EgPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Row(
                title: app.langs.t('set.theme'),
                hint: app.langs.t('set.themeHint'),
                ctl: EgSeg<EgThemeMode>(
                  options: [
                    (EgThemeMode.light, app.langs.t('th.light')),
                    (EgThemeMode.dark, app.langs.t('th.dark')),
                    (EgThemeMode.system, app.langs.t('th.system')),
                  ],
                  value: app.prefs.themeMode,
                  onChanged: app.setThemeMode,
                ),
              ),
              _Row(
                title: app.langs.t('set.nav'),
                hint: app.langs.t('set.navHint'),
                ctl: EgSeg<EgNavMode>(
                  options: [
                    (EgNavMode.side, app.langs.t('nav.side')),
                    (EgNavMode.top, app.langs.t('nav.top')),
                  ],
                  value: app.prefs.navMode,
                  onChanged: app.setNavMode,
                ),
              ),
              _appearanceBody(app, c),
            ],
          ),
        ),

        EgPanel(
          child: Column(
            children: [
              _Row(
                title: app.langs.t('set.name'),
                hint: app.langs.t('set.nameHint'),
                ctl: EgInput(controller: _name, width: 150, maxLength: 24, onChanged: app.setName),
              ),
              _Row(
                last: true,
                title: app.langs.t('set.lang'),
                hint: app.langs.t('set.langHint'),
                ctl: EgDropdown<String>(
                  items: [for (final code in EgLangs.codes) (code, app.langs.metaName(code))],
                  value: app.langs.cur,
                  onChanged: app.setLang,
                ),
              ),
            ],
          ),
        ),

        if (app.canElevate)
          EgPanel(
            child: _Row(
              last: true,
              title: app.langs.t('set.perm'),
              hint: app.admin == true
                  ? app.langs.t('set.permAdminHint')
                  : app.room == RoomState.idle
                      ? app.langs.t('set.permUserHint')
                      : app.langs.t('set.permBusyHint'),
              ctl: app.admin == true
                  ? EgTag(app.langs.t('set.permAdmin'), color: c.acc)
                  : EgButton(
                      label: _restarting ? app.langs.t('set.permRestarting') : app.langs.t('btn.restartAdmin'),
                      kind: EgBtnKind.primary,
                      onPressed: _restarting || app.room != RoomState.idle ? null : () => _restartAsAdmin(app),
                    ),
            ),
          ),

        EgPanel(
          child: Column(
            children: [
              _Row(
                title: app.langs.t('set.port'),
                hint: app.langs.t('set.portHint'),
                ctl: EgInput(
                  controller: _port,
                  mono: true,
                  maxLength: 5,
                  formatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _commitNet(app),
                ),
              ),
              _Row(
                title: app.langs.t('set.mtu'),
                hint: app.langs.t('set.mtuHint'),
                ctl: EgInput(
                  controller: _mtu,
                  mono: true,
                  maxLength: 4,
                  formatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _commitNet(app),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(app.langs.t('set.stun'), style: egText(c, size: 14, weight: FontWeight.w600, height: 1.5)),
                              Text(app.langs.t('set.stunHint'), style: egText(c, size: 12.5, color: c.muted, height: 1.4)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        EgInput(
                          controller: _stun,
                          width: 260,
                          mono: true,
                          hint: Prefs.defaultStun,
                          maxLength: 128,
                          onChanged: (_) => setState(() {
                            _stunError = null;
                            _stunResult = null;
                          }),
                          onSubmitted: (_) => _testStun(app),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(app.langs.t('set.stunNote'), style: egText(c, size: 12.5, color: c.muted, height: 1.55)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _stunError != null
                              ? Text(_stunError!, style: egText(c, size: 12.5, color: c.bad, height: 1.45))
                              : _stunResult != null
                                  ? Text(_stunResult!, style: egText(c, size: 12.5, color: c.acc, height: 1.45))
                                  : const SizedBox.shrink(),
                        ),
                        EgButton(label: app.langs.t('set.stunReset'), onPressed: _stunTesting ? null : () => _resetStun(app)),
                        const SizedBox(width: 8),
                        EgButton(
                          label: _stunTesting ? app.langs.t('set.stunTesting') : app.langs.t('set.stunTest'),
                          kind: EgBtnKind.primary,
                          onPressed: _stunTesting ? null : () => _testStun(app),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        EgPanel(
          child: Column(
            children: [
              _Row(title: app.langs.t('set.version'), ctl: EgTag('v0.1.0-dev', color: c.faint)),
              _Row(
                last: true,
                title: app.langs.t('set.license'),
                hint: app.langs.t('set.licenseHint'),
                ctl: EgTag(app.langs.t('tag.apache')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- 外观----
  // 紧凑分组头:授色花标 + 标题 + 反色药丸重置。
  Widget _appearanceHeader(AppState app, EgColors c) {
    final a = app.appearance;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
      decoration: BoxDecoration(
        color: c.acc,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CustomPaint(painter: _ScallopPainter(color: a.seed, stroke: c.accInk, strokeWidth: 2)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(app.langs.t('set.themeSection'),
                    style: egDisplay(c, size: 17, weight: FontWeight.w800, color: c.accInk, height: 1.2)),
                const SizedBox(height: 1),
                Text(app.langs.t('set.themeManageBody'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: egText(c, size: 11.5, color: c.accInk.withValues(alpha: 0.82), height: 1.35)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _ResetPill(
            label: app.langs.t('set.themeReset'),
            bg: c.accInk,
            fg: c.acc,
            onTap: () => _resetAll(app),
          ),
        ],
      ),
    );
  }

  Widget _appearanceBody(AppState app, EgColors c) {
    final a = app.appearance;
    final light = a.colorsFor(Brightness.light);
    final dark = a.colorsFor(Brightness.dark);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          // 紧凑分组头:花瓣形色标 + 标题 + 反色药丸重置;高度约 60,不再占据首屏。
          _appearanceHeader(app, c),

          // 主色:调色盘按钮 + 16 进制输入(两者双向同步),靠右
          _settingRow(
            title: app.langs.t('set.themeSeed'),
            hint: app.langs.t('set.themeSeedHint'),
            control: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _PickSwatchButton(
                    seed: a.seed,
                    onTap: () => _openColorDialog(app),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 210,
                    child: EgInput(controller: _seed, mono: true, maxLength: 9,
                        onChanged: (v) => _onSeedChanged(app, v), onSubmitted: (v) => _onSeedChanged(app, v)),
                  ),
                ],
              ),
            ),
          ),
          if (_seedError != null)
            Text(app.langs.t('set.themeErrColor'), style: egText(c, size: 12, color: c.bad)),

          // 彩虹预设:点击即用为主色。
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final color in AppAppearance.rainbowSeeds)
                _RainbowChip(
                  color: color,
                  selected: a.seed == color,
                  onTap: () => _setSeed(app, color),
                ),
            ],
          ),

          // 字体:显示标题已固定为无衬线,仅正文/等宽可改。
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.langs.t('set.themeFont'),
                    style: egText(c, size: 14, weight: FontWeight.w700, color: c.text)),
                const SizedBox(height: 2),
                Text(app.langs.t('set.themeFontHint'), style: egText(c, size: 12, color: c.muted)),
              ],
            ),
          ),
          _settingRow(
            title: app.langs.t('set.themeFontBody'),
            control: EgDropdown<String>(
              items: [for (final f in ThemeTypography.allowedFamilies.keys) (f, f)],
              value: _textFamily,
              onChanged: (v) => _setFont(app, 'text', v),
            ),
          ),
          _settingRow(
            title: app.langs.t('set.themeFontMono'),
            control: EgDropdown<String>(
              items: [for (final f in ThemeTypography.allowedFamilies.keys) (f, f)],
              value: _monoFamily,
              onChanged: (v) => _setFont(app, 'mono', v),
            ),
          ),

          // 加粗字体:全局 M3 emphasized 字重开关
          _settingRow(
            title: app.langs.t('set.themeWeight'),
            hint: app.langs.t('set.themeWeightHint'),
            control: Switch(value: a.bold, onChanged: (v) => _update(app, bold: v)),
          ),

          // 字号
          _settingRow(
            title: app.langs.t('set.themeSize'),
            hint: app.langs.t('set.themeSizeHint'),
            control: _Stepper(
              c: c,
              minus: app.langs.t('set.themeSizeDown'),
              plus: app.langs.t('set.themeSizeUp'),
              textCtl: _sizeScale,
              step: 0.05,
              min: 0.85,
              max: 2.0,
              fmt: (v) => v.toStringAsFixed(2),
              onChange: (v) => _update(app, size: v),
            ),
          ),

          // 圆角
          _settingRow(
            title: app.langs.t('set.themeRadius'),
            hint: app.langs.t('set.themeRadiusHint'),
            control: _Stepper(
              c: c,
              minus: app.langs.t('set.themeRadiusDown'),
              plus: app.langs.t('set.themeRadiusUp'),
              textCtl: _radiusScale,
              step: 0.05,
              min: 0.0,
              max: 1.3,
              fmt: (v) => v.toStringAsFixed(2),
              onChange: (v) => _update(app, radius: v),
            ),
          ),

          // 预览
          Row(
            children: [
              _swatch(c, light, app.langs.t('th.light')),
              const SizedBox(width: 10),
              _swatch(c, dark, app.langs.t('th.dark')),
            ],
          ),
        ],
      ),
    );
  }

  void _setFont(AppState app, String key, String family) {
    final a = app.appearance;
    final t = a.typography;
    app.setAppearance(a.copyWith(typography: t.copyWith(
      display: key == 'display' ? family : t.display,
      text: key == 'text' ? family : t.text,
      mono: key == 'mono' ? family : t.mono,
    )));
    setState(() {
      if (key == 'display') {
        _displayFamily = family;
      } else if (key == 'text') {
        _textFamily = family;
      } else {
        _monoFamily = family;
      }
    });
  }

  void _openColorDialog(AppState app) {
    final c = Eg.of(context).c;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: c.overlay,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, __) => EgSkinDialog(
        title: app.langs.t('set.themeSeed'),
        child: _HsvPicker(
          initial: app.appearance.seed,
          onChanged: (color) => _setSeed(app, color),
        ),
        actions: [EgButton(label: app.langs.t('btn.close'), onPressed: () => Navigator.pop(ctx))],
      ),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  // 数值编辑器:− [文本框] +;± 为文字按钮,有交互感。
  Widget _Stepper({
    required EgColors c,
    required String minus,
    required String plus,
    required TextEditingController textCtl,
    required double step,
    required double min,
    required double max,
    required String Function(double v) fmt,
    required ValueChanged<double> onChange,
  }) {
    void commit(double delta) {
      final cur = double.tryParse(textCtl.text) ?? 0;
      final next = (cur + delta).clamp(min, max).toDouble();
      if (next == cur) return;
      textCtl.text = fmt(next);
      onChange(next);
    }

    Widget btn(String label, double delta) {
      return _StepBtn(label: label, onTap: () => commit(delta));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(minus, -step),
        const SizedBox(width: 5),
        SizedBox(
          width: 74,
          child: EgInput(controller: textCtl, mono: true, maxLength: 6, readOnly: true,
              center: true, fontSize: 18, weight: FontWeight.w800),
        ),
        const SizedBox(width: 5),
        btn(plus, step),
      ],
    );
  }

  Widget _settingRow({required String title, String? hint, required Widget control}) {
    final c = Eg.of(context).c;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: BoxDecoration(
        color: c.panel2,
        borderRadius: BorderRadius.circular(28),
        boxShadow: c.panelShadow,
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: egText(c, size: 14, weight: FontWeight.w600, color: c.text)),
                if (hint != null) Text(hint, style: egText(c, size: 12, color: c.muted)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 340, maxWidth: 420),
            child: Align(alignment: Alignment.centerRight, child: control),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _swatch(EgColors c, EgColors t, String label) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        height: 72,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: c.line2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: egText(c, size: 12, color: t.text, weight: FontWeight.w600)),
            const Spacer(),
            Row(
              children: [
                for (final color in [t.acc, t.accDim, t.warn, t.panel2]) ...[
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.only(right: 7),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: t.line2.withValues(alpha: 0.5)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 调色盘:饱和度/明度面板 + 色相条 + 精确滑块,预览与 16 进制同步。
  Widget _HsvPicker({required Color initial, required ValueChanged<Color> onChanged}) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final start = _hsvOf(initial);
    double h = start.h, s = start.s, v = start.v;
    Color current = initial;
    const panelW = 280.0;
    const panelH = 170.0;

    Timer? debounce;
    return StatefulBuilder(
      builder: (ctx, setPicker) {
        // 拖动时只刷新面板,提交延迟 90ms;松手立即提交。
        // setAppearance 每次都重算配色并写盘,拖动逐帧提交是卡顿主因。
        void emit({double? nh, double? ns, double? nv, bool immediate = false}) {
          h = nh ?? h;
          s = (ns ?? s).clamp(0.0, 1.0);
          v = (nv ?? v).clamp(0.0, 1.0);
          current = _colorFromHsv(h: h, s: s, v: v);
          setPicker(() {});
          debounce?.cancel();
          if (immediate) {
            debounce = null;
            if (ctx.mounted) onChanged(current);
          } else {
            debounce = Timer(const Duration(milliseconds: 90), () {
              if (ctx.mounted) onChanged(current);
            });
          }
        }

        void pickSV(Offset p) => emit(
              ns: (p.dx / panelW).clamp(0.0, 1.0),
              nv: (1 - p.dy / panelH).clamp(0.0, 1.0),
            );

        void pickHue(Offset p) => emit(nh: (p.dx / panelW * 360).clamp(0.0, 360.0));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            // 横轴饱和度、纵轴明度的取色面板
            GestureDetector(
              onPanDown: (d) => pickSV(d.localPosition),
              onPanUpdate: (d) => pickSV(d.localPosition),
              onPanEnd: (_) => emit(immediate: true),
              onPanCancel: () => emit(immediate: true),
              child: Stack(
                children: [
                  Container(
                    width: panelW,
                    height: panelH,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(colors: [Colors.white, _colorFromHsv(h: h, s: 1, v: 1)]),
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0xFF000000)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: s * (panelW - 14),
                    top: (1 - v) * (panelH - 14),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 4)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 色相条:红→黄→绿→青→蓝→品红→红
            GestureDetector(
              onPanDown: (d) => pickHue(d.localPosition),
              onPanUpdate: (d) => pickHue(d.localPosition),
              onPanEnd: (_) => emit(immediate: true),
              onPanCancel: () => emit(immediate: true),
              child: Stack(
                children: [
                  Container(
                    width: panelW,
                    height: 20,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(100),
                      gradient: const LinearGradient(colors: [
                        Color(0xFFFF0000),
                        Color(0xFFFFFF00),
                        Color(0xFF00FF00),
                        Color(0xFF00FFFF),
                        Color(0xFF0000FF),
                        Color(0xFFFF00FF),
                        Color(0xFFFF0000),
                      ]),
                    ),
                  ),
                  Positioned(
                    left: h / 360 * (panelW - 10),
                    top: -3,
                    child: Container(
                      width: 10,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.line2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Container(width: 40, height: 40, decoration: BoxDecoration(
                  color: current, shape: BoxShape.circle, border: Border.all(color: c.line2))),
                const SizedBox(width: 12),
                Text(hexOf(current), style: egMono(c, size: 14, weight: FontWeight.w600)),
              ],
            ),
            _HsvSlider(label: app.langs.t('set.themeSeedHue'), value: h, min: 0, max: 360, step: 1, fmt: (v) => '${v.round()}°', onChanged: (x) => emit(nh: x), onChangeEnd: (x) => emit(nh: x, immediate: true)),
            _HsvSlider(label: app.langs.t('set.themeSeedSat'), value: s, min: 0, max: 1, step: 0.01, fmt: (v) => '${(v * 100).round()}%', onChanged: (x) => emit(ns: x), onChangeEnd: (x) => emit(ns: x, immediate: true)),
            _HsvSlider(label: app.langs.t('set.themeSeedVal'), value: v, min: 0, max: 1, step: 0.01, fmt: (v) => '${(v * 100).round()}%', onChanged: (x) => emit(nv: x), onChangeEnd: (x) => emit(nv: x, immediate: true)),
          ],
        );
      },
    );
  }

  Widget _HsvSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required double step,
    required String Function(double) fmt,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final c = Eg.of(context).c;
    return Row(
      children: [
        SizedBox(width: 88, child: Text(label, style: egMono(c, size: 13))),
        const SizedBox(width: 8),
        SizedBox(
          width: 220,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 40, child: Text(fmt(value), style: egMono(c, size: 13, weight: FontWeight.w600))),
      ],
    );
  }

  // HSV 近似算法:仅用于从 seed 解析初值。
  _HsvColorS _hsvOf(Color color) {
    final r = color.r.clamp(0.0, 1.0);
    final g = color.g.clamp(0.0, 1.0);
    final b = color.b.clamp(0.0, 1.0);
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    final v = mx;
    final delta = mx - mn;
    final s = mx == 0 ? 0.0 : delta / mx;
    double h;
    if (delta == 0) {
      h = 0;
    } else if (mx == r) {
      h = (60 * ((g - b) / delta) + 360) % 360;
    } else if (mx == g) {
      h = (60 * ((b - r) / delta + 2)) % 360;
    } else {
      h = (60 * ((r - g) / delta + 4)) % 360;
    }
    return _HsvColorS(h: h, s: s, v: v);
  }

  Color _colorFromHsv({required double h, required double s, required double v}) {
    final hh = h % 360;
    final i = (hh / 60).floor() % 6;
    final f = hh / 60 - (hh / 60).floor();
    final p = v * (1 - s);
    final q = v * (1 - f * s);
    final t = v * (1 - (1 - f) * s);
    final rr, gg, bb;
    switch (i) {
      case 0: rr = v; gg = t; bb = p;
      case 1: rr = q; gg = v; bb = p;
      case 2: rr = p; gg = v; bb = t;
      case 3: rr = p; gg = q; bb = v;
      case 4: rr = t; gg = p; bb = v;
      default: rr = v; gg = p; bb = q;
    }
    return Color(0xFF000000 | ((rr * 255).toInt() << 16) | ((gg * 255).toInt() << 8) | ((bb * 255).toInt()));
  }

  // ---- 工具函数 ----
  Color? parseHex(String s) {
    final hex = s.trim();
    if (!hex.startsWith('#')) return null;
    final v = int.tryParse(hex.substring(1), radix: 16);
    if (v == null) return null;
    return Color(0xFF000000 | v);
  }

  String hexOf(Color color) {
    final v = color.toARGB32();
    return '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

// 花瓣形色标:余弦波轮廓,颜色取自当前主色。
class _ScallopPainter extends CustomPainter {
  final Color color;
  final Color? stroke;
  final double strokeWidth;
  const _ScallopPainter({required this.color, this.stroke, this.strokeWidth = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.shortestSide / 2 - 2;
    final path = Path();
    const steps = 180;
    for (var i = 0; i <= steps; i++) {
      final a = i / steps * math.pi * 2;
      final r = base * (0.86 + 0.14 * math.cos(a * 10));
      final p = center + Offset(math.cos(a) * r, math.sin(a) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    final shadow = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawPath(path.shift(const Offset(0, 3)), shadow);
    canvas.drawPath(path, Paint()..color = color);
    if (stroke != null && strokeWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = stroke!,
      );
    }
  }

  @override
  bool shouldRepaint(_ScallopPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.stroke != stroke || oldDelegate.strokeWidth != strokeWidth;
}

// 恢复默认:紧凑药丸,悬停放大、按下回弹。
class _ResetPill extends StatefulWidget {
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;
  const _ResetPill({required this.label, required this.bg, required this.fg, required this.onTap});

  @override
  State<_ResetPill> createState() => _ResetPillState();
}

class _ResetPillState extends State<_ResetPill> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _down ? 0.94 : (_hover ? 1.04 : 1),
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            boxShadow: c.panelShadow,
          ),
          child: Material(
            color: _hover ? Color.lerp(widget.bg, widget.fg, 0.07)! : widget.bg,
            shape: const StadiumBorder(),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(100),
              onTapDown: (_) => setState(() => _down = true),
              onTapUp: (_) => setState(() => _down = false),
              onTapCancel: () => setState(() => _down = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.restart_alt, size: 15, color: widget.fg),
                    const SizedBox(width: 6),
                    Text(widget.label, style: egText(c, size: 12, weight: FontWeight.w700, color: widget.fg)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 主色按钮:圆盘色样,悬停外扩并投影,按下收缩。
class _PickSwatchButton extends StatefulWidget {
  final Color seed;
  final VoidCallback onTap;
  const _PickSwatchButton({required this.seed, required this.onTap});

  @override
  State<_PickSwatchButton> createState() => _PickSwatchButtonState();
}

class _PickSwatchButtonState extends State<_PickSwatchButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final ink = widget.seed.computeLuminance() > 0.62 ? Colors.black87 : Colors.white;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.9 : (_hover ? 1.07 : 1),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.seed,
              border: Border.all(color: _hover ? c.acc : c.line2, width: _hover ? 2 : 1),
              boxShadow: [
                BoxShadow(
                  color: widget.seed.withValues(alpha: _hover ? 0.42 : 0.22),
                  blurRadius: _hover ? 20 : 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(Icons.palette_outlined, size: 19, color: ink),
          ),
        ),
      ),
    );
  }
}

// 步进器按钮:容器色药丸,悬停加深、按下回弹。
class _StepBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _StepBtn({required this.label, required this.onTap});

  @override
  State<_StepBtn> createState() => _StepBtnState();
}

class _StepBtnState extends State<_StepBtn> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.86 : (_hover ? 1.06 : 1),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _hover ? c.acc.withValues(alpha: 0.22) : c.accDim,
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text(widget.label, style: egText(c, size: 17, weight: FontWeight.w800, color: c.acc)),
          ),
        ),
      ),
    );
  }
}

// 一行设置:左标题+注脚,右控件;行间以细线分隔,末行无线。
class _Row extends StatelessWidget {
  final String title;
  final String? hint;
  final Widget ctl;
  final bool last;
  const _Row({required this.title, this.hint, required this.ctl, this.last = false});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.line))),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: egText(c, size: 14, weight: FontWeight.w600, height: 1.5)),
                if (hint != null) Text(hint!, style: egText(c, size: 12.5, color: c.muted, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ctl,
        ],
      ),
    );
  }
}
