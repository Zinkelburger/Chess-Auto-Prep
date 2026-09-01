#include "single_instance.h"

#include "win32_window.h"

namespace {

// Per-session, so two users on one machine each get their own instance.
constexpr wchar_t kMutexName[] = L"Local\\ChessAutoPrep.Instance";

// Held for the life of the process; the OS releases it on exit.
HANDLE g_instance_mutex = nullptr;

// The running instance may still be starting up (two files double-clicked
// together), so give its window a moment to appear.
HWND FindRunningInstance() {
  for (int attempt = 0; attempt < 50; ++attempt) {
    HWND window = ::FindWindowW(kWindowClassName, nullptr);
    if (window != nullptr) return window;
    ::Sleep(100);
  }
  return nullptr;
}

}  // namespace

bool ClaimSingleInstance(const std::vector<std::string>& paths) {
  g_instance_mutex = ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (g_instance_mutex == nullptr ||
      ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return true;
  }

  HWND target = FindRunningInstance();
  if (target == nullptr) {
    // Cannot reach it: better a second window than a click that does
    // nothing.
    return true;
  }

  if (!paths.empty()) {
    std::string payload;
    for (const std::string& path : paths) {
      if (!payload.empty()) payload += '\n';
      payload += path;
    }
    COPYDATASTRUCT data{};
    data.dwData = kOpenFilesCopyData;
    data.cbData = static_cast<DWORD>(payload.size());
    data.lpData = const_cast<char*>(payload.data());
    ::SendMessageW(target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data));
  }

  if (::IsIconic(target)) ::ShowWindow(target, SW_RESTORE);
  ::SetForegroundWindow(target);
  return false;
}

std::vector<std::string> DecodeOpenFiles(const COPYDATASTRUCT& data) {
  std::vector<std::string> paths;
  if (data.dwData != kOpenFilesCopyData || data.lpData == nullptr) {
    return paths;
  }
  std::string payload(static_cast<const char*>(data.lpData), data.cbData);
  size_t start = 0;
  while (start <= payload.size()) {
    size_t end = payload.find('\n', start);
    if (end == std::string::npos) end = payload.size();
    if (end > start) paths.push_back(payload.substr(start, end - start));
    start = end + 1;
  }
  return paths;
}
