import Cocoa
import FlutterMacOS

// Frameless window. The native side keeps only window-manager primitives;
// the title, buttons and their look are drawn by Flutter.
class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame

    // Keep .titled so AppKit still draws rounded corners and supports native
    // window dragging; fullSizeContentView lets Flutter paint under the bar.
    if !styleMask.contains(.titled) {
      styleMask.insert(.titled)
    }
    if !styleMask.contains(.resizable) {
      styleMask.insert(.resizable)
    }
    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    title = "EverGreen LAN"

    // The brand buttons live in Flutter at the top right, so the system ones
    // have to go. They are hidden, not removed, to keep the title bar height.
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    minSize = NSSize(width: 960, height: 640)
    contentMinSize = NSSize(width: 960, height: 640)

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    installDragOverlay()
    installWindowChannel(flutterViewController)

    super.awakeFromNib()
  }

  // AppKit, not Flutter, owns window dragging on macOS. An invisible NSView
  // over the title bar turns pointer presses into a native window drag.
  // 40 and 138 must stay in sync with EgTitleBar in lib/widgets/title_bar.dart.
  private func installDragOverlay() {
    guard let content = contentView else { return }
    let overlay = DragOverlayView()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      overlay.topAnchor.constraint(equalTo: content.topAnchor),
      overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -138),
      overlay.heightAnchor.constraint(equalToConstant: 40),
    ])
  }

  // Window buttons and the maximized-state query. startMove/startResize are
  // intentionally not implemented here: the drag overlay and AppKit's resize
  // border already cover those gestures.
  private func installWindowChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "eglan/window",
      binaryMessenger: controller.engine.binaryMessenger)
    windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "minimize":
        self.miniaturize(nil)
        result(nil)
      case "maximizeToggle":
        self.zoom(nil)
        result(nil)
      case "close":
        self.close()
        result(nil)
      case "isMaximized":
        result(self.isZoomed)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// Transparent hit region for the custom title bar. Double-clicking toggles
// maximize, a plain press and drag moves the window with all native behaviour
// (screen-edge snapping, Spaces) intact.
private final class DragOverlayView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return true
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.performZoom(nil)
    } else {
      window?.performWindowDrag(with: event)
    }
  }
}
