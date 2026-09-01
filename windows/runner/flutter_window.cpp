#include "flutter_window.h"

#include <optional>

#include "desktop_integration.h"
#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"

namespace {

// Posted once the first frame is up, so the .pgn offer (a modal box) is shown
// from the message loop rather than from inside the engine's frame callback.
constexpr UINT kDesktopIntegrationMessage = WM_APP + 1;

}  // namespace

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
  file_open_channel_.Attach(flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    ::PostMessageW(GetHandle(), kDesktopIntegrationMessage, 0, 0);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OpenFiles(const std::vector<std::string>& paths) {
  file_open_channel_.Open(paths);
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_COPYDATA: {
      // Files forwarded by a second instance (see single_instance.h).
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data != nullptr && data->dwData == kOpenFilesCopyData) {
        file_open_channel_.Open(DecodeOpenFiles(*data));
        return TRUE;
      }
      break;
    }
    case kDesktopIntegrationMessage:
      DesktopIntegrationMaybeSetup(hwnd);
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
