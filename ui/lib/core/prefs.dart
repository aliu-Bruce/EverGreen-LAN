// 界面偏好持久化:%APPDATA%\eglan\ui.json,纯 dart:io,无第三方依赖。
import 'dart:convert';
import 'dart:io';

enum EgThemeMode { light, dark, system }
enum EgNavMode { side, top }

class Prefs {
  static const defaultStun = 'stun.cloudflare.com:3478';
  // 旧版本的默认值;升级时只有仍在使用它的用户会被迁移到新默认。
  static const legacyStun = 'stun.l.google.com:19302';

  EgThemeMode themeMode = EgThemeMode.dark;
  EgNavMode navMode = EgNavMode.side;
  String lang = '';
  String name = '';
  int port = 47777;
  int mtu = 1400;
  String stun = defaultStun;
  bool onboarded = false;
  // 外观参数(主色/字体/字号/圆角);旧主题字段已废弃,启动后会被清理。
  Map<String, dynamic>? appearance;

  File? _file;

  static File? _resolve() {
    final path = resolvePath(
      isWindows: Platform.isWindows,
      isMacOS: Platform.isMacOS,
      env: Platform.environment,
    );
    return path == null ? null : File(path);
  }

  // 配置位置与平台有关,与文件系统无关;单独成函数便于跨平台测试。
  static String? resolvePath({
    required bool isWindows,
    required bool isMacOS,
    required Map<String, String> env,
  }) {
    if (isWindows) {
      final appData = env['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return '$appData\\eglan\\ui.json';
    }
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    if (isMacOS) return '$home/Library/Application Support/eglan/ui.json';
    final xdg = env['XDG_CONFIG_HOME'];
    final base = (xdg == null || xdg.isEmpty) ? '$home/.config' : xdg;
    return '$base/eglan/ui.json';
  }

  // 启动即读;文件损坏按默认值处理,不阻塞界面。
  void loadSync() {
    _file = _resolve();
    final f = _file;
    if (f == null) return;
    try {
      final obj = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      themeMode = switch (obj['themeMode']) {
        'light' => EgThemeMode.light,
        'system' => EgThemeMode.system,
        _ => EgThemeMode.dark,
      };
      navMode = obj['navMode'] == 'top' ? EgNavMode.top : EgNavMode.side;
      lang = (obj['lang'] as String?) ?? '';
      name = (obj['name'] as String?) ?? '';
      port = (obj['port'] as num?)?.toInt() ?? 47777;
      mtu = (obj['mtu'] as num?)?.toInt() ?? 1400;
      final savedStun = (obj['stun'] as String?)?.trim() ?? '';
      stun = savedStun.isEmpty || savedStun == legacyStun ? defaultStun : savedStun;
      onboarded = obj['onboarded'] == true;
      final a = obj['appearance'];
      appearance = a is Map ? Map<String, dynamic>.from(a) : null;
    } catch (_) {}
  }

  // 任何字段变化后调用;失败静默(偏好丢失可接受)。
  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'themeMode': themeMode.name,
        'navMode': navMode.name,
        'lang': lang,
        'name': name,
        'port': port,
        'mtu': mtu,
        'stun': stun,
        'onboarded': onboarded,
        if (appearance != null) 'appearance': appearance,
      }));
    } catch (_) {}
  }
}
