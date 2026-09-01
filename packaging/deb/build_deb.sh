#!/usr/bin/env bash
# Packages the built Linux bundle as a .deb for Debian, Ubuntu, Mint and kin.
#
#   packaging/deb/build_deb.sh <version> [bundle-dir] [output-dir]
#
# Run after `flutter build linux --release` (and, for a release, the
# libcdbdirect dependency-bundling step in release.yml). The bundle goes to
# /opt/chess-auto-prep with a /usr/bin symlink, so the shared desktop entry
# (linux/com.example.chess_auto_prep.desktop, Exec=chess_auto_prep %f) works
# unchanged and .pgn files open here. dpkg's desktop-file and icon triggers
# refresh the caches; no postinst needed.
set -euo pipefail

VERSION="${1:?usage: build_deb.sh <version> [bundle-dir] [output-dir]}"
BUNDLE="${2:-build/linux/x64/release/bundle}"
OUT="${3:-dist}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_ID=com.example.chess_auto_prep

test -x "$BUNDLE/chess_auto_prep" || {
  echo "no bundle at $BUNDLE — run flutter build linux --release first" >&2
  exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

install -d \
  "$STAGE/opt/chess-auto-prep" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/128x128/apps" \
  "$STAGE/usr/share/metainfo" \
  "$STAGE/DEBIAN"

cp -a "$BUNDLE"/. "$STAGE/opt/chess-auto-prep/"
ln -s /opt/chess-auto-prep/chess_auto_prep "$STAGE/usr/bin/chess_auto_prep"
install -m644 "$ROOT/linux/$APP_ID.desktop" "$STAGE/usr/share/applications/"
install -m644 "$ROOT/linux/$APP_ID.png" \
  "$STAGE/usr/share/icons/hicolor/128x128/apps/"
install -m644 "$ROOT/packaging/flatpak/$APP_ID.metainfo.xml" \
  "$STAGE/usr/share/metainfo/"

INSTALLED_KB="$(du -sk "$STAGE" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: chess-auto-prep
Version: $VERSION
Section: games
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0, libglib2.0-0, libstdc++6
Maintainer: Andrew Bernal <andrewlbernal@gmail.com>
Homepage: https://github.com/Zinkelburger/Chess-Auto-Prep
Description: Chess repertoire and tactics trainer
 Builds and trains opening repertoires, finds tactics in your own games,
 analyses positions with Stockfish, and opens PGN files.
EOF

mkdir -p "$OUT"
dpkg-deb --build --root-owner-group "$STAGE" \
  "$OUT/chess-auto-prep-$VERSION-linux-amd64.deb"
