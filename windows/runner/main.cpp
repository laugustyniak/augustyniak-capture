#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

void RegisterAuthProtocol() {
  constexpr wchar_t kScheme[] = L"ai.augustyniak.capture";
  wchar_t executable[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return;

  const std::wstring key_path =
      std::wstring(L"Software\\Classes\\") + kScheme;
  HKEY protocol_key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0, nullptr, 0,
                      KEY_WRITE, nullptr, &protocol_key, nullptr) !=
      ERROR_SUCCESS) {
    return;
  }

  const std::wstring description = std::wstring(L"URL:") + kScheme;
  RegSetValueExW(protocol_key, nullptr, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(description.c_str()),
                 static_cast<DWORD>((description.size() + 1) * sizeof(wchar_t)));
  const wchar_t empty[] = L"";
  RegSetValueExW(protocol_key, L"URL Protocol", 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(empty), sizeof(empty));

  HKEY command_key;
  if (RegCreateKeyExW(protocol_key, L"shell\\open\\command", 0, nullptr, 0,
                      KEY_WRITE, nullptr, &command_key, nullptr) ==
      ERROR_SUCCESS) {
    const std::wstring command =
        L"\"" + std::wstring(executable, length) + L"\" \"%1\"";
    RegSetValueExW(command_key, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(command.c_str()),
                   static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(command_key);
  }
  RegCloseKey(protocol_key);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }
  RegisterAuthProtocol();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Augustyniak Capture", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
