// 自绘标题栏:窗口去掉系统边框后,标题、拖动与窗口按钮全部自己画。
// 原生侧只保留三件事——移动/缩放交给窗口管理器、最小化最大化关闭、
// 报告最大化状态;三平台共用同一条 eglan/window 方法通道。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// 窗口原生操作入口。方法名在三个 runner 中保持一致,缺实现时静默降级。
class EgWindow {
  static const MethodChannel _channel = MethodChannel('eglan/window');

  /// 桌面三平台都改为无边框 + 自绘标题栏;其余平台仍由系统提供窗口装饰。
  static bool get framed => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 只有 Linux 没有原生缩放边框,四周的缩放把手必须自己补。
  static bool get needsResizeHandles => Platform.isLinux;

  static Future<void> _send(String method, [Object? argument]) async {
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on PlatformException {
      // 原生侧未就绪时降级:窗口仍在,只是少了这条捷径。
    } on MissingPluginException {
      // 同上。
    }
  }

  static Future<void> minimize() => _send('minimize');

  static Future<void> maximizeToggle() => _send('maximizeToggle');

  static Future<void> close() => _send('close');

  static Future<void> startMove() => _send('startMove');

  /// edge 取 n/s/e/w/ne/nw/se/sw,与原生的窗口边缘一一对应。
  static Future<void> startResize(String edge) => _send('startResize', edge);

  /// 最大化状态:原生没有可订阅的上行事件,退一步用轮询跟随。
  static Future<bool> isMaximized() async {
    try {
      return await _channel.invokeMethod<bool>('isMaximized') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// 自绘标题栏:左边是标题与整片拖动区,右边是三个窗口按钮。
class EgTitleBar extends StatefulWidget {
  const EgTitleBar({super.key});

  /// 标题栏高度;窗口正文整体下移同样的距离。
  static const double height = 40;

  /// 右侧按钮簇宽度(3 × 46)。macOS 的原生拖动遮罩按它让位,
  /// 三平台的拖动区因此都是 [0, 宽度 - 138]。
  static const double buttonsWidth = 138;

  @override
  State<EgTitleBar> createState() => _EgTitleBarState();
}

class _EgTitleBarState extends State<EgTitleBar> {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _followMaximize();
  }

  // 轮询跟随最大化状态:原生侧没有状态变化的上行事件。
  Future<void> _followMaximize() async {
    while (mounted) {
      final next = await EgWindow.isMaximized();
      if (!mounted) return;
      if (next != _maximized) setState(() => _maximized = next);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Container(
      height: EgTitleBar.height,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      child: Row(
        children: [
          // 拖动区:按下即把指针交给窗口管理器,移动全程由系统接管。
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                if (event.kind == PointerDeviceKind.touch ||
                    (event.buttons & kPrimaryMouseButton) != 0) {
                  EgWindow.startMove();
                }
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 15,
                        height: 15,
                        child: Image(image: AssetImage('assets/icon/icon.png'), fit: BoxFit.cover),
                      ),
                      const SizedBox(width: 8),
                      Text('EverGreen LAN', style: egText(c, size: 12, color: c.muted)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: EgTitleBar.buttonsWidth,
            child: Row(
              children: [
                _TitleButton(icon: Icons.remove, onPress: EgWindow.minimize),
                _TitleButton(
                  icon: _maximized ? Icons.filter_none : Icons.crop_square,
                  onPress: EgWindow.maximizeToggle,
                ),
                _TitleButton(icon: Icons.close, danger: true, onPress: EgWindow.close),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// 窗口按钮:悬停时才出底色,关闭键染品牌红并反白图标。
class _TitleButton extends StatefulWidget {
  final IconData icon;
  final bool danger;
  final VoidCallback onPress;
  const _TitleButton({required this.icon, required this.onPress, this.danger = false});

  @override
  State<_TitleButton> createState() => _TitleButtonState();
}

class _TitleButtonState extends State<_TitleButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final bg = !_hover ? Colors.transparent : (widget.danger ? c.bad : c.panel2);
    final fg = _hover && widget.danger ? Colors.white : c.muted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPress,
        child: Container(
          width: EgTitleBar.buttonsWidth / 3,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg),
          child: Icon(widget.icon, size: 14, color: fg),
        ),
      ),
    );
  }
}

/// Linux 的缩放把手:窗口没有系统边框,四周贴边按下即交给窗口管理器。
/// 只画命中区,不画任何可见装饰;顶边与右边让出标题栏的按钮簇。
class EgResizeHandles extends StatelessWidget {
  const EgResizeHandles({super.key});

  /// 把手厚度,与主流桌面的命中区域一致。
  static const double thickness = 8;

  @override
  Widget build(BuildContext context) {
    Widget grab(String edge, MouseCursor cursor) => MouseRegion(
          cursor: cursor,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (event.kind == PointerDeviceKind.touch ||
                  (event.buttons & kPrimaryMouseButton) != 0) {
                EgWindow.startResize(edge);
              }
            },
          ),
        );

    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: thickness,
          height: thickness,
          child: grab('nw', SystemMouseCursors.resizeUpLeft),
        ),
        Positioned(
          left: 0,
          top: thickness,
          bottom: thickness,
          width: thickness,
          child: grab('w', SystemMouseCursors.resizeLeft),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: thickness,
          height: thickness,
          child: grab('sw', SystemMouseCursors.resizeDownLeft),
        ),
        Positioned(
          left: thickness,
          right: EgTitleBar.buttonsWidth,
          top: 0,
          height: thickness,
          child: grab('n', SystemMouseCursors.resizeUp),
        ),
        Positioned(
          left: thickness,
          right: thickness,
          bottom: 0,
          height: thickness,
          child: grab('s', SystemMouseCursors.resizeDown),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          width: thickness,
          height: thickness,
          child: grab('se', SystemMouseCursors.resizeDownRight),
        ),
        Positioned(
          right: 0,
          top: EgTitleBar.height,
          bottom: thickness,
          width: thickness,
          child: grab('e', SystemMouseCursors.resizeRight),
        ),
      ],
    );
  }
}
