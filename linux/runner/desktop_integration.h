#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

#include <gtk/gtk.h>

// Offers (once) to install a .desktop entry and icon into the user's XDG data
// directories, and keeps them up to date on later launches if accepted.
// Wayland compositors can only show a window icon by matching the app-id to
// an installed desktop entry, so portable builds (itch.io zip) need this.
// No-op inside Flatpak, which installs the desktop entry itself.
void desktop_integration_maybe_setup(GtkWindow* parent_window);

#endif  // RUNNER_DESKTOP_INTEGRATION_H_
