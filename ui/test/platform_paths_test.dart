// 平台差异的纯路径逻辑:核心探测与偏好位置。
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/ipc.dart';
import '../lib/core/prefs.dart';

void main() {
  test('核心探测:Windows 用 exe 后缀与反斜杠', () {
    final paths = IpcBridge.probeCandidates(
      r'C:\Apps\EGLAN',
      r'C:\Apps\EGLAN',
      true,
    );
    expect(paths.first, r'C:\Apps\EGLAN\egland.exe');
    expect(paths, contains(r'C:\Apps\EGLAN\dist\egland.exe'));
    expect(paths.every((p) => p.endsWith('egland.exe')), isTrue);
  });

  test('核心探测:macOS/Linux 无后缀且用正斜杠', () {
    final paths = IpcBridge.probeCandidates(
      '/Applications/EGLAN.app/Contents/MacOS',
      '/Users/me',
      false,
    );
    expect(paths.first, '/Applications/EGLAN.app/Contents/MacOS/egland');
    expect(paths, contains('/Users/me/dist/egland'));
    expect(paths.every((p) => p.endsWith('egland')), isTrue);
    expect(paths.every((p) => !p.contains(r'\')), isTrue);
  });

  test('偏好位置:三平台各自落在系统配置目录', () {
    expect(
      Prefs.resolvePath(
        isWindows: true,
        isMacOS: false,
        env: {'APPDATA': r'C:\Users\me\AppData\Roaming'},
      ),
      r'C:\Users\me\AppData\Roaming\eglan\ui.json',
    );
    expect(
      Prefs.resolvePath(
        isWindows: false,
        isMacOS: true,
        env: {'HOME': '/Users/me'},
      ),
      '/Users/me/Library/Application Support/eglan/ui.json',
    );
    expect(
      Prefs.resolvePath(
        isWindows: false,
        isMacOS: false,
        env: {'HOME': '/home/me'},
      ),
      '/home/me/.config/eglan/ui.json',
    );
    expect(
      Prefs.resolvePath(
        isWindows: false,
        isMacOS: false,
        env: {'HOME': '/home/me', 'XDG_CONFIG_HOME': '/home/me/xdg'},
      ),
      '/home/me/xdg/eglan/ui.json',
    );
  });
}
