#include "flutter_window.h"

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  ocr_bridge_ = std::make_unique<OcrBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "quelyt/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        const std::string& method = call.method_name();
        if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success(
              flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "isMaximized") {
          result->Success(
              flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "startDrag") {
          ReleaseCapture();
          SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
        } else if (method == "startResize") {
          const auto* edge = std::get_if<std::string>(call.arguments());
          WPARAM hit_test = 0;
          if (edge != nullptr) {
            if (*edge == "top") {
              hit_test = HTTOP;
            } else if (*edge == "bottom") {
              hit_test = HTBOTTOM;
            } else if (*edge == "left") {
              hit_test = HTLEFT;
            } else if (*edge == "right") {
              hit_test = HTRIGHT;
            } else if (*edge == "topLeft") {
              hit_test = HTTOPLEFT;
            } else if (*edge == "topRight") {
              hit_test = HTTOPRIGHT;
            } else if (*edge == "bottomLeft") {
              hit_test = HTBOTTOMLEFT;
            } else if (*edge == "bottomRight") {
              hit_test = HTBOTTOMRIGHT;
            }
          }
          if (hit_test == 0) {
            result->Error("bad_edge", "Unknown resize edge");
          } else {
            ReleaseCapture();
            SendMessage(hwnd, WM_NCLBUTTONDOWN, hit_test, 0);
            result->Success();
          }
        } else if (method == "close") {
          result->Success();
          DestroyWindow(hwnd);
          ExitProcess(0);
        } else {
          result->NotImplemented();
        }
      });
  window_maximized_ = IsZoomed(GetHandle()) != 0;

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  window_channel_.reset();
  ocr_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Remove the native caption before the Flutter engine sees the message.
  // Flutter's top-level window proc otherwise claims NCCALCSIZE and leaves the
  // system title bar above our custom caption.
  if (message == WM_NCCALCSIZE && wparam == TRUE) {
    return 0;
  }
  if (message == WM_NCHITTEST || message == WM_GETMINMAXINFO) {
    // Resize edges and work-area bounds are runner responsibilities; the
    // engine's top-level proc should not consume them.
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  if (message == WM_CLOSE) {
    DestroyWindow(hwnd);
    ExitProcess(0);
  }
  if (message == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  if (ocr_bridge_ && ocr_bridge_->HandleWindowMessage(message, lparam)) {
    return 0;
  }
  if (message == WM_SIZE && window_channel_) {
    const bool maximized = IsZoomed(hwnd) != 0;
    if (maximized != window_maximized_) {
      window_maximized_ = maximized;
      window_channel_->InvokeMethod(
          "maximized",
          std::make_unique<flutter::EncodableValue>(maximized));
    }
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
