#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Whether the source asked clipboard managers to leave the current content
// alone (#302). Windows has two conventions, both registered clipboard
// formats: `ExcludeClipboardContentFromMonitorProcessing`, whose mere
// presence is the signal, and `CanIncludeInClipboardHistory`, a DWORD where
// 0 means "do not record". Password managers set one or both; a source that
// sets neither is observed as before.
bool ClipboardIsSensitive() {
  const UINT exclude =
      RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
  if (exclude != 0 && IsClipboardFormatAvailable(exclude)) {
    return true;
  }
  const UINT history = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
  if (history == 0 || !IsClipboardFormatAvailable(history)) {
    return false;
  }
  if (!OpenClipboard(nullptr)) {
    // Another process holds the clipboard open; this poll reads the content
    // unflagged, the same outcome as a source that set no hint.
    return false;
  }
  bool sensitive = false;
  HANDLE handle = GetClipboardData(history);
  if (handle != nullptr) {
    const DWORD* value = static_cast<const DWORD*>(GlobalLock(handle));
    if (value != nullptr) {
      sensitive = *value == 0;
      GlobalUnlock(handle);
    }
  }
  CloseClipboard();
  return sensitive;
}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The same channel the macOS and Android runners answer. Only the
  // sensitive hint is implemented here; every other method stays
  // `NotImplemented`, which the Dart side already treats as "no image
  // support on this platform".
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "ai.augustyniak.capture/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "isClipboardSensitive") {
          result->Success(flutter::EncodableValue(ClipboardIsSensitive()));
        } else {
          result->NotImplemented();
        }
      });

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
  // Before the controller: the channel holds the engine's messenger.
  clipboard_channel_ = nullptr;
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
