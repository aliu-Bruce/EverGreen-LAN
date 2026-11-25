import Cocoa
import FlutterMacOS

// Fully frameless window: no AppKit title strip and no system border. Flutter
// draws every pixel, including the title row and the rounded corners. The
// native side only supplies dragging, resizing and the three window actions.
class MainFlutterWindow: NSWindow {
  // Keep in sync with lib/widgets/title_bar.dart:
  // EgTitleBar.height, EgTitleBar.buttonsWidth.
  private static let flutterBarHeight: CGFloat = 40
  private static let flutterButtonsWidth: CGFloat = 138
  private static let cornerRadius: CGFloat = 12
  private static let minContentWidth: CGFloat = 960
  private static let minContentHeight: CGFloat = 640

  private var windowChannel: FlutterMethodChannel?
  private var dragOverlay: NSView?
  private var zoomedByUs = false
  private var frameBeforeZoom: NSRect?

  // A borderless window does not become key on its own.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()

    styleMask = [.borderless]
    isMovableByWindowBackground = false
    backgroundColor = .clear

    minSize = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
    contentMinSize = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)

    // Flutter's surface lives in a clipping container so the page itself
    // paints the rounded corners a borderless window no longer gets from AppKit.
    let container = NSView(frame: flutterViewController.view.frame)
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.masksToBounds = true
    flutterViewController.view.frame = container.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    container.addSubview(flutterViewController.view)
    self.contentView = container

    // The xib opens at a template size below the app minimum. Grow the frame
    // before the first frame so the window never appears smaller than 960x640.
    growToMinimumSize()

    RegisterGeneratedPlugins(registry: flutterViewController)
    installWindowChannel(flutterViewController)
    installDragOverlay()

    super.awakeFromNib()
  }

  // Enlarges a below-minimum window once and keeps it centered.
  private func growToMinimumSize() {
    let minimum = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
    let current = contentView?.frame.size ?? frame.size
    guard current.width < minimum.width || current.height < minimum.height else {
      return
    }
    setContentSize(NSSize(width: max(current.width, minimum.width),
                          height: max(current.height, minimum.height)))
    center()
  }

  // Transparent hit region over the Flutter title row. A press hands the window
  // to the window server for a native drag; double click toggles our own zoom.
  private func installDragOverlay() {
    guard let content = contentView else { return }
    let overlay = DragOverlayView()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      overlay.trailingAnchor.constraint(
        equalTo: content.trailingAnchor, constant: -Self.flutterButtonsWidth),
      overlay.topAnchor.constraint(equalTo: content.topAnchor),
      overlay.heightAnchor.constraint(equalToConstant: Self.flutterBarHeight),
    ])
    dragOverlay = overlay
  }

  // Window actions, maximized-state query and the palette mirror. Resizing is
  // driven by Flutter's edge handles through startResize below.
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
        self.toggleZoom()
        result(nil)
      case "close":
        // One window per app: terminating is deterministic, while close() can
        // leave the engine and the core child process alive.
        result(nil)
        NSApp.terminate(nil)
      case "isMaximized":
        result(self.zoomedByUs || self.isZoomed)
      case "setBackdrop":
        // Sits behind the Flutter surface, visible only through the rounded
        // corners; keep it in step with the page palette.
        if let argb = (call.arguments as? NSNumber)?.intValue {
          let red = CGFloat((argb >> 16) & 0xFF) / 255.0
          let green = CGFloat((argb >> 8) & 0xFF) / 255.0
          let blue = CGFloat(argb & 0xFF) / 255.0
          self.backgroundColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        result(nil)
      case "startResize":
        guard let edge = call.arguments as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.startResize(edge)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Borderless windows have no native zoom button, so keep the previous frame
  // ourselves and use the monitor's visible frame (never covering the dock).
  func toggleZoom() {
    if zoomedByUs, let previous = frameBeforeZoom {
      setFrame(previous, display: true)
      frameBeforeZoom = nil
      zoomedByUs = false
      return
    }
    guard let screen = screen ?? NSScreen.main else { return }
    frameBeforeZoom = frame
    setFrame(screen.visibleFrame, display: true)
    zoomedByUs = true
  }

  // Follow an edge drag with a frame resize loop. Screen coordinates are used
  // directly so the grab point does not jump at the first movement.
  private func startResize(_ edge: String) {
    let start = NSEvent.mouseLocation
    let original = frame
    var left = original.minX
    var right = original.maxX
    var bottom = original.minY
    var top = original.maxY
    let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

    while let event = NSApp.nextEvent(
      matching: mask, until: Date.distantFuture, inMode: .eventTracking, dequeue: true) {
      if event.type == .leftMouseUp { break }
      let now = NSEvent.mouseLocation
      let dx = now.x - start.x
      let dy = now.y - start.y
      if edge.contains("w") { left = original.minX + dx }
      if edge.contains("e") { right = original.maxX + dx }
      if edge.contains("s") { bottom = original.minY + dy }
      if edge.contains("n") { top = original.maxY + dy }
      if right - left < Self.minContentWidth {
        if edge.contains("w") {
          left = right - Self.minContentWidth
        } else {
          right = left + Self.minContentWidth
        }
      }
      if top - bottom < Self.minContentHeight {
        if edge.contains("s") {
          bottom = top - Self.minContentHeight
        } else {
          top = bottom + Self.minContentHeight
        }
      }
      setFrame(NSRect(x: left, y: bottom, width: right - left, height: top - bottom),
               display: true)
    }
  }
}

// Transparent hit region over the Flutter title row. Nothing is drawn; a press
// only hands the window to the window server for a native drag.
private final class DragOverlayView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return true
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      (window as? MainFlutterWindow)?.toggleZoom()
    } else {
      window?.performDrag(with: event)
    }
  }
}
