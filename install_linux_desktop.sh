#!/bin/bash
# Installs the desktop entry and icon so the app menu, title bar and taskbar
# show Chess Auto Prep with the knook icon.
#
#   install_linux_desktop.sh [--bundle DIR]
#
# With --bundle, DIR is a built Linux bundle (the folder holding the
# chess_auto_prep executable, its lib/ and data/). It is copied to
# ~/.local/share/chess-prep/app and the entry starts that copy, so cleaning
# or rebuilding the checkout never leaves the menu entry pointing at nothing.
# Run it again after a new build to refresh the copy.
#
# Without --bundle the entry starts `chess_auto_prep` from PATH, as a
# packaged install does.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_SRC="${SCRIPT_DIR}/linux/com.example.chess_auto_prep.desktop"
ICON_SRC="${SCRIPT_DIR}/assets/images/knook.png"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="${DATA_DIR}/applications"
ICONS_DIR="${DATA_DIR}/icons/hicolor"
APP_DIR="${DATA_DIR}/chess-prep/app"

BUNDLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)
      [[ $# -ge 2 ]] || { echo "Error: --bundle needs a folder" >&2; exit 2; }
      BUNDLE="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--bundle DIR]" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$DESKTOP_SRC" ]]; then
  echo "Error: Desktop file not found at $DESKTOP_SRC" >&2
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Error: Icon not found at $ICON_SRC" >&2
  exit 1
fi

EXEC="chess_auto_prep"
if [[ -n "$BUNDLE" ]]; then
  if [[ ! -x "$BUNDLE/chess_auto_prep" ]]; then
    echo "Error: no chess_auto_prep executable in $BUNDLE" >&2
    exit 1
  fi
  # Built beside the old copy and swapped in, so a failed copy leaves the
  # entry starting the build it had.
  STAGING="${APP_DIR}.new"
  rm -rf "$STAGING"
  mkdir -p "$(dirname "$APP_DIR")"
  cp -a "$BUNDLE" "$STAGING"
  rm -rf "${APP_DIR}.old"
  [[ -d "$APP_DIR" ]] && mv "$APP_DIR" "${APP_DIR}.old"
  mv "$STAGING" "$APP_DIR"
  rm -rf "${APP_DIR}.old"
  EXEC="'${APP_DIR}/chess_auto_prep'"
fi

mkdir -p "$APPS_DIR"
mkdir -p "$ICONS_DIR/256x256/apps"
mkdir -p "$ICONS_DIR/48x48/apps"

sed "s|^Exec=.*|Exec=${EXEC} %f|" "$DESKTOP_SRC" \
  > "$APPS_DIR/com.example.chess_auto_prep.desktop"
# The entry's Icon is the application id; older installs used the short name.
for size in 256x256 48x48; do
  cp "$ICON_SRC" "$ICONS_DIR/$size/apps/com.example.chess_auto_prep.png"
  cp "$ICON_SRC" "$ICONS_DIR/$size/apps/chess_auto_prep.png"
done

# Refresh desktop database (optional, helps some environments)
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -qtf "$ICONS_DIR" 2>/dev/null || true
fi

echo "Installed the Chess Auto Prep desktop entry and icon."
if [[ -n "$BUNDLE" ]]; then
  echo "It starts the copy in $APP_DIR."
fi
