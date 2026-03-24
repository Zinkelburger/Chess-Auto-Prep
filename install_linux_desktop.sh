#!/bin/bash
# Installs .desktop file and icon so KDE Wayland (and other DEs) show the
# knook icon in the title bar and taskbar instead of the generic icon.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_SRC="${SCRIPT_DIR}/linux/com.example.chess_auto_prep.desktop"
ICON_SRC="${SCRIPT_DIR}/assets/images/knook.png"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"

if [[ ! -f "$DESKTOP_SRC" ]]; then
  echo "Error: Desktop file not found at $DESKTOP_SRC"
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Error: Icon not found at $ICON_SRC"
  exit 1
fi

mkdir -p "$APPS_DIR"
mkdir -p "$ICONS_DIR/256x256/apps"
mkdir -p "$ICONS_DIR/48x48/apps"

cp "$DESKTOP_SRC" "$APPS_DIR/"
cp "$ICON_SRC" "$ICONS_DIR/256x256/apps/chess_auto_prep.png"
cp "$ICON_SRC" "$ICONS_DIR/48x48/apps/chess_auto_prep.png"

# Refresh desktop database (optional, helps some environments)
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -qtf "$ICONS_DIR" 2>/dev/null || true
fi

echo "Installed Chess Auto Prep desktop entry and icon."
echo "Restart the app (or close and run 'flutter run -d linux' again) to see the knook icon."
