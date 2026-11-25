// 统一权限错误出口:任意路径上报、监听去重、清空、提权后重试标识。
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/app_state.dart';

void main() {
  test('权限关键词命中时写入统一字段并带重试标识', () {
    final app = AppState();
    var notified = 0;
    app.addListener(() => notified++);

    app.reportPermissionError('建虚拟网卡失败(需要管理员权限)', retryKind: 'create');
    expect(app.permissionError, '建虚拟网卡失败(需要管理员权限)');
    expect(app.permissionRetryKind, 'create');
    expect(notified, 1);
  });

  test('非权限错误不进统一字段', () {
    final app = AppState();
    app.reportPermissionError('房间码无效', retryKind: 'join');
    expect(app.permissionError, isNull);
    expect(app.permissionRetryKind, isNull);
  });

  test('已提权仍记录权限错误,失败原因必须可见', () {
    final app = AppState()..admin = true;
    app.reportPermissionError('建虚拟网卡失败(需要管理员权限)', retryKind: 'join');
    expect(app.permissionError, '建虚拟网卡失败(需要管理员权限)');
    expect(app.permissionRetryKind, 'join');
  });

  test('清空后字段与重试标识都复位', () {
    final app = AppState();
    app.reportPermissionError('权限被拒', retryKind: 'join');
    app.clearPermissionError();
    expect(app.permissionError, isNull);
    expect(app.permissionRetryKind, isNull);
  });

  test('加入失败与创建失败都汇入同一出口,重试标识各自保留', () {
    final app = AppState();
    app.reportPermissionError('建虚拟网卡失败(需要管理员权限)', retryKind: 'join');
    expect(app.permissionRetryKind, 'join');
    app.clearPermissionError();
    app.reportPermissionError('建虚拟网卡失败(需要管理员权限)', retryKind: 'create');
    expect(app.permissionRetryKind, 'create');
  });
}
