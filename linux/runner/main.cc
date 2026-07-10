#include "my_application.h"

int main(int argc, char** argv) {
  // TODO: Remove once we're on a Flutter release containing
  // https://github.com/flutter/flutter/pull/187626 (not in stable 3.44.x).
  // Until then, running under X11/XWayland uses a CPU frame-copy path in the
  // engine that segfaults when the window is resized larger before a new
  // frame is ready (flutter/flutter#187589). Environments like VS Code's
  // integrated terminal export GDK_BACKEND=x11 even on Wayland sessions, so
  // prefer the Wayland backend whenever a Wayland compositor is available.
  if (g_getenv("WAYLAND_DISPLAY") != nullptr) {
    g_setenv("GDK_BACKEND", "wayland", TRUE);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
