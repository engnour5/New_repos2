#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  // Open centred on the main screen: as large as the design wants, but never larger than the screen.
  RECT work;
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const POINT top_left = {work.left, work.top};
  const double scale =
      FlutterDesktopGetDpiForMonitor(::MonitorFromPoint(top_left, MONITOR_DEFAULTTOPRIMARY)) / 96.0;
  const int work_w = static_cast<int>((work.right - work.left) / scale);
  const int work_h = static_cast<int>((work.bottom - work.top) / scale);
  const int width = std::min(1440, work_w - 40);
  const int height = std::min(920, work_h - 40);
  Win32Window::Point origin(
      static_cast<unsigned int>(static_cast<int>(work.left / scale) + (work_w - width) / 2),
      static_cast<unsigned int>(static_cast<int>(work.top / scale) + (work_h - height) / 2));
  Win32Window::Size size(static_cast<unsigned int>(width), static_cast<unsigned int>(height));
  if (!window.Create(L"iPhone NFC Tester", origin, size)) {
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
