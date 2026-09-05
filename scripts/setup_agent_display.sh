#!/usr/bin/env bash
# Install a user-local Xvfb on Fedora, without sudo or a reboot.
set -euo pipefail
if command -v Xvfb >/dev/null; then
  echo 'Xvfb is already available'; exit 0
fi
DEST="$HOME/.local/share/chess-prep/xvfb"
if [[ -x "$DEST/usr/bin/Xvfb" ]]; then
  echo "Xvfb available at $DEST/usr/bin/Xvfb"; exit 0
fi
if ! command -v dnf >/dev/null; then
  echo 'Install Xvfb with your package manager (Ubuntu/Debian: sudo apt install xvfb dbus-x11).' >&2
  exit 2
fi
RPMS=$(mktemp -d)
trap 'rm -rf "$RPMS"' EXIT
dnf --repo=fedora --repo=updates download --resolve --destdir="$RPMS" xorg-x11-server-Xvfb
mkdir -p "$DEST"
for rpm in "$RPMS"/*.rpm; do
  rpmkeys --checksig "$rpm"
  (cd "$DEST" && rpm2cpio "$rpm" | cpio -idm --quiet --no-absolute-filenames)
done
echo "Installed $DEST/usr/bin/Xvfb"
