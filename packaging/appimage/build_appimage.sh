#!/usr/bin/env bash
# Packages the built Linux bundle as an AppImage: one file that runs on any
# x86_64 desktop and replaces itself when the app updates.
#
#   packaging/appimage/build_appimage.sh <tag> [bundle-dir] [output-dir]
#
# Run after `flutter build linux --release`. Writes
# chess-auto-prep-<tag>-linux-x86_64.AppImage, the name the in-app updater
# looks for. appimagetool and the type-2 runtime are pinned by SHA-256 and
# kept in APPIMAGE_TOOLS (default build/appimage-tools). The runtime is
# static, so the AppImage needs no libfuse2 on the user's machine.
set -euo pipefail

TAG="${1:?usage: build_appimage.sh <tag> [bundle-dir] [output-dir]}"
BUNDLE="${2:-build/linux/x64/release/bundle}"
OUT="${3:-dist}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="${APPIMAGE_TOOLS:-$ROOT/build/appimage-tools}"
APP_ID=com.example.chess_auto_prep

test -x "$BUNDLE/chess_auto_prep" || {
  echo "no bundle at $BUNDLE — run flutter build linux --release first" >&2
  exit 1
}

# Downloads <url> to $TOOLS/<name> once, and insists on <sha256> every time.
fetch() {
  local url=$1 name=$2 sha=$3 dest="$TOOLS/$2"
  mkdir -p "$TOOLS"
  if ! test -f "$dest"; then
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv -- "$dest.part" "$dest"
  fi
  echo "$sha  $dest" | sha256sum -c --quiet - || {
    echo "$name does not match its pinned SHA-256; delete $dest to fetch again" >&2
    exit 1
  }
  chmod +x -- "$dest"
}
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  appimagetool-x86_64.AppImage ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
fetch https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 \
  runtime-x86_64 2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APPDIR="$STAGE/AppDir"
mkdir -p "$APPDIR"

# The bundle as it is: Flutter finds lib/ and data/ beside its executable.
cp -a "$BUNDLE"/. "$APPDIR/"
rm -f -- "$APPDIR/.chess-auto-prep-portable"
ln -s chess_auto_prep "$APPDIR/AppRun"
install -m644 "$ROOT/linux/$APP_ID.desktop" "$APPDIR/"
install -m644 "$ROOT/linux/$APP_ID.png" "$APPDIR/"
ln -s "$APP_ID.png" "$APPDIR/.DirIcon"

mkdir -p "$OUT"
TARGET="$OUT/chess-auto-prep-$TAG-linux-x86_64.AppImage"
# Extract-and-run: appimagetool is itself an AppImage, and build machines
# often have no FUSE.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOLS/appimagetool-x86_64.AppImage" \
  --no-appstream --runtime-file "$TOOLS/runtime-x86_64" "$APPDIR" "$TARGET"

# The updater refuses anything else: "AI" and type 2 at byte 8.
test "$(od -An -tx1 -j8 -N3 -- "$TARGET" | tr -d ' \n')" = 414902
ls -l "$TARGET"
