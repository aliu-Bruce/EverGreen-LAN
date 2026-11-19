// 设置页:外观(主题/导航)、身份(用户名)、权限、网络(端口/MTU/STUN)、关于。
// 只放有真实后端支撑的项。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/prefs.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

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
  bool _inited = false;
  bool _restarting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_inited) {
      final app = AppState.of(context);
      _name.text = app.prefs.name;
      _port.text = '${app.prefs.port}';
      _mtu.text = '${app.prefs.mtu}';
      _stun.text = app.prefs.stun;
      _inited = true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    _mtu.dispose();
    _stun.dispose();
    super.dispose();
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

  // 留空表示仍用默认服务器;提交时把规范化后的值回填到输入框。
  void _commitStun(AppState app) {
    app.setStun(_stun.text);
    _stun.text = app.prefs.stun.isEmpty ? Prefs.defaultStun : app.prefs.stun;
    if (_stun.text != app.prefs.stun) {
      app.setStun(_stun.text);
    }
  }

  // 提权只换后台核心:成功后本界面继续运行,不需要退出。
  Future<void> _restartAsAdmin(AppState app) async {
    if (_restarting) return;
    setState(() => _restarting = true);
    final err = await app.elevateCore();
    if (!mounted) return;
    setState(() => _restarting = false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
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
        Text(app.langs.t('set.title'), style: egDisplay(c, size: 30, letterSpacing: -0.01, height: 1.2)),

        // 外观
        EgPanel(
          child: Column(
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
              // 自定义主题:界面颜色全部来自主题令牌
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: '${app.langs.t('set.custom')} ', style: egText(c, size: 13, weight: FontWeight.w600, color: c.text)),
                            TextSpan(text: app.langs.t('set.customBody'), style: egText(c, size: 12.5, color: c.muted, height: 1.6)),
                          ],
                        ),
                      ),
                    ),
                    EgChip(app.langs.t('chip.wip')),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 身份与语言
        EgPanel(
          child: Column(
            children: [
              _Row(
                title: app.langs.t('set.name'),
                hint: app.langs.t('set.nameHint'),
                ctl: EgInput(
                  controller: _name,
                  width: 140,
                  mono: false,
                  center: false,
                  maxLength: 24,
                  onChanged: (v) => app.setName(v),
                ),
              ),
              _Row(
                last: true,
                title: app.langs.t('set.lang'),
                hint: app.langs.t('set.langHint'),
                ctl: EgDropdown<String>(
                  items: [
                    for (final code in EgLangs.codes)
                      (code, app.langs.metaName(code)),
                  ],
                  value: app.langs.cur,
                  onChanged: app.setLang,
                ),
              ),
            ],
          ),
        ),

        // 运行权限:只有支持一键提权的平台显示;提权后开房与发现放行才完整。
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
                      small: true,
                      onPressed: _restarting || app.room != RoomState.idle ? null : () => _restartAsAdmin(app),
                    ),
            ),
          ),

        // 网络
        EgPanel(
          child: Column(
            children: [
              _Row(
                last: false,
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
                last: false,
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
              _Row(
                last: true,
                title: app.langs.t('set.stun'),
                hint: app.langs.t('set.stunHint'),
                ctl: EgInput(
                  controller: _stun,
                  width: 220,
                  mono: true,
                  hint: Prefs.defaultStun,
                  maxLength: 128,
                  onChanged: app.setStun,
                  onSubmitted: (_) => _commitStun(app),
                ),
              ),
            ],
          ),
        ),

        // 关于
        EgPanel(
          child: Column(
            children: [
              _Row(
                last: false,
                title: app.langs.t('set.version'),
                ctl: EgTag('v0.1.0-dev', color: c.faint),
              ),
              _Row(
                last: true,
                title: app.langs.t('set.license'),
                hint: app.langs.t('set.licenseHint'),
                ctl: EgTag(app.langs.t('tag.pending')),
              ),
            ],
          ),
        ),
      ],
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
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: egText(c, size: 13, weight: FontWeight.w600, height: 1.5)),
              if (hint != null)
                Text(hint!, style: egText(c, size: 11.5, color: c.muted, height: 1.4)),
            ],
          ),
          const Spacer(),
          ctl,
        ],
      ),
    );
  }
}
