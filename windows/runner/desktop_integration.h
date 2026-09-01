#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

#include <windows.h>

// Offers (once) to make this app the default for .pgn files, and keeps the
// registration pointing at this executable on later launches if accepted.
// Everything goes under HKEY_CURRENT_USER, so no elevation is needed. The
// installer records the same choice, so an installed copy is never asked.
void DesktopIntegrationMaybeSetup(HWND parent_window);

#endif  // RUNNER_DESKTOP_INTEGRATION_H_
