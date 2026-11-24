import Cocoa
import FlutterMacOS

// Frameless window. The native side keeps only the window-manager primitives;
// the title, the buttons and their look are drawn by Flutter.
class MainFlutterWindow: NSWindow {
  // Must stay in sync with lib/widgets/title_bar.dart:
  // EgWindow.reservedTopInset, EgTitleBar.height, EgTitleBar.buttonsWidth.
  private static let reservedTopInset: CGFloat = 28
  private static let flutterBarHeight: CGFloat = 40
  private static let flutterButtonsWidth: CGFloat = 138

  private var windowChannel: FlutterMethodChannel?
  private var dragOverlay: NSView?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame

    // Keep .titled: AppKit owns the rounded corners, the resize border and the
    // drag strip along the very top of the window.
    if !styleMask.contains(.titled) {
      styleMask.insert(.titled)
    }
    if !styleMask.contains(.resizable) {
      styleMask.insert(.resizable)
    }
    if !styleMask.contains(.closable) {
      styleMask.insert(.closable)
    }
    if !styleMask.contains(.miniaturizable) {
      styleMask.insert(.miniaturizable)
    }
    // fullSizeContentView lets the Flutter surface paint under the title bar.
    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    title = "EverGreen LAN"

    // The brand buttons live in Flutter at the top right, so the system ones
    // have to go.
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    isMovableByWindowBackground = false

    minSize = NSSize(width: 960, height: 640)
    contentMinSize = NSSize(width: 960, height: 640)

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    installWindowChannel(flutterViewController)
    installDragOverlay()

    super.awakeFromNib()
  }

  // AppKit's title bar keeps the top `reservedTopInset` points of the window for
  // itself and swallows presses there, so Flutter draws its own title row just
  // below that strip and this overlay covers exactly the Flutter row, minus the
  // button cluster. The buttons therefore stay fully reachable for Flutter and
  // the rest of the row still moves the window natively.
  private func installDragOverlay() {
    guard let content = contentView else { return }
    let overlay = DragOverlayView()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      overlay.trailingAnchor.constraint(
        equalTo: content.trailingAnchor, constant: -Self.flutterButtonsWidth),
      overlay.topAnchor.constraint(equalTo: content.topAnchor,
                                  constant: Self.reservedTopInset),
      overlay.heightAnchor.constraint(equalToConstant: Self.flutterBarHeight),
    ])
    dragOverlay = overlay
  }

  // Window buttons and the maximized-state query. startMove/startResize are not
  // implemented here: the overlay above and AppKit's resize border own dragging.
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
        // One window per app: closing it is quitting. Terminating explicitly is
        // deterministic, while close() only orders the window out and can leave
        // the engine and the core child process alive.
        result(nil)
        NSApp.terminate(nil)
      case "isMaximized":
        result(self.isZoomed)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// Transparent hit region over the Flutter title row. Nothing is drawn; a press
// only hands the window to the window server for a native drag, so screen-edge
// snapping and Space switching keep working.
private final class DragOverlayView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return true
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.performZoom(nil)
    } else {
      window?.performDrag(with: event)
    }
  }
}
