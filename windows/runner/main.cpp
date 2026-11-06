#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

namespace {

/// Logical startup bounds. The window is centered inside the monitor work area
/// and never opens larger than the screen; the old fixed 1440x960 could spill
/// off a 1366x768 laptop or a 200% DPI display.
constexpr int kPreferredWidth = 1440;
constexpr int kPreferredHeight = 960;
constexpr int kMinimumWidth = 600;
constexpr int kMinimumHeight = 480;
constexpr int kWorkAreaMargin = 48;

}  // namespace

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
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(kPreferredWidth, kPreferredHeight);

  const POINT anchor = {10, 10};
  HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (GetMonitorInfo(monitor, &monitor_info)) {
    const double scale =
        FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
    const int work_width = static_cast<int>(
        (monitor_info.rcWork.right - monitor_info.rcWork.left) / scale);
    const int work_height = static_cast<int>(
        (monitor_info.rcWork.bottom - monitor_info.rcWork.top) / scale);
    const int width = std::max(
        kMinimumWidth,
        std::min(kPreferredWidth, work_width - kWorkAreaMargin));
    const int height = std::max(
        kMinimumHeight,
        std::min(kPreferredHeight, work_height - kWorkAreaMargin));
    const int left = std::max(
        0, static_cast<int>((monitor_info.rcWork.left -
                             monitor_info.rcMonitor.left) /
                            scale) +
               (work_width - width) / 2);
    const int top = std::max(
        0, static_cast<int>((monitor_info.rcWork.top -
                             monitor_info.rcMonitor.top) /
                            scale) +
               (work_height - height) / 2);
    size = Win32Window::Size(width, height);
    origin = Win32Window::Point(static_cast<unsigned int>(left),
                                static_cast<unsigned int>(top));
  }

  if (!window.Create(L"Quelyt", origin, size)) {
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
