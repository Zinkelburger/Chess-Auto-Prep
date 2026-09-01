#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>
#include <vector>

// One window per session. Windows starts a fresh process for every
// double-clicked .pgn; a process that finds the app already running hands
// that instance its files (or just raises it) and exits.

// Tries to become the app's instance. Returns true when this process is it.
// Returns false when another instance is running and has been given |paths|
// (UTF-8) — the caller should exit without creating a window.
bool ClaimSingleInstance(const std::vector<std::string>& paths);

// dwData of the WM_COPYDATA message carrying forwarded paths.
constexpr ULONG_PTR kOpenFilesCopyData = 0x43415000;  // 'CAP\0'

// The paths carried by a kOpenFilesCopyData message.
std::vector<std::string> DecodeOpenFiles(const COPYDATASTRUCT& data);

#endif  // RUNNER_SINGLE_INSTANCE_H_
