#include "flutter_window.h"

#include <flutter/encodable_value.h>

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Minimum window size in logical pixels. Handled before the Flutter embedder
// gets a chance to answer WM_GETMINMAXINFO, so the custom title bar's layout
// budget always holds.
constexpr int kMinWindowWidth = 960;
constexpr int kMinWindowHeight = 640;

// Maps a resize edge name from the Dart side to a Win32 non-client hit test
// value, so the system runs its own native resize loop.
UINT EdgeHit(const std::string& edge) {
  if (edge == "n") return HTTOP;
  if (edge == "s") return HTBOTTOM;
  if (edge == "e") return HTRIGHT;
  if (edge == "w") return HTLEFT;
  if (edge == "ne") return HTTOPRIGHT;
  if (edge == "nw") return HTTOPLEFT;
  if (edge == "se") return HTBOTTOMRIGHT;
  if (edge == "sw") return HTBOTTOMLEFT;
  return HTNOWHERE;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

// Native half of the custom title bar. The window has no system caption, so
// moving and resizing work by translating a mouse message into a non-client
// hit test and letting the system enter its native loop.
void FlutterWindow::SetupWindowChannel() {
  window_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "eglan/window",
      &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const HWND hwnd = GetHandle();
        if (hwnd == nullptr) {
          result->Error("no_window", "window is gone");
          return;
        }
        const std::string& method = call.method_name();
        if (method == "minimize") {
          ::SendMessage(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
          result->Success();
        } else if (method == "maximizeToggle") {
          ::SendMessage(hwnd, WM_SYSCOMMAND,
                        ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
          result->Success();
        } else if (method == "close") {
          ::PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(::IsZoomed(hwnd) != 0));
        } else if (method == "startMove" || method == "startResize") {
          UINT hit = HTCAPTION;
          if (method == "startResize") {
            const auto* args = call.arguments();
            hit = args != nullptr && std::holds_alternative<std::string>(*args)
                      ? EdgeHit(std::get<std::string>(*args))
                      : HTNOWHERE;
          }
          if (hit == HTNOWHERE) {
            result->Error("bad_edge", "unknown resize edge");
            return;
          }
          ::ReleaseCapture();
          ::SendMessage(hwnd, WM_NCLBUTTONDOWN, hit, 0);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetupWindowChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Drop the channel before the engine so a late call cannot reach a torn
  // down Flutter instance.
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_GETMINMAXINFO) {
    // The embedder may also constrain the window from its own box constraints;
    // answer first so our minimum size wins. Scale by the window DPI so a
    // high-DPI monitor cannot shrink the window below 960x640 physical pixels.
    const UINT dpi = GetDpiForWindow(hwnd);
    if (dpi != 0) {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x =
          MulDiv(kMinWindowWidth, static_cast<int>(dpi), 96);
      info->ptMinTrackSize.y =
          MulDiv(kMinWindowHeight, static_cast<int>(dpi), 96);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
