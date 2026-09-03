#!/usr/bin/env bash
# Packages the built Linux bundle as an .rpm for Fedora, RHEL, openSUSE and kin.
#
#   packaging/rpm/build_rpm.sh <version> [bundle-dir] [output-dir]
#
# The counterpart of packaging/deb/build_deb.sh, and deliberately the same
# shape: same arguments, same staged layout (/opt/chess-auto-prep plus a
# /usr/bin symlink), so the shared desktop entry works unchanged and .pgn
# files open here too. Run it after `flutter build linux --release` and the
# libcdbdirect dependency-bundling step in release.yml.
#
# No %post scriptlets: Fedora ships file triggers on /usr/share/applications
# and /usr/share/icons/hicolor that refresh the desktop and icon caches, the
# same way dpkg's triggers do for the .deb.
set -euo pipefail

VERSION="${1:?usage: build_rpm.sh <version> [bundle-dir] [output-dir]}"
BUNDLE="${2:-build/linux/x64/release/bundle}"
OUT="${3:-dist}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_ID=com.example.chess_auto_prep

test -x "$BUNDLE/chess_auto_prep" || {
  echo "no bundle at $BUNDLE — run flutter build linux --release first" >&2
  exit 1
}

# RPM versions may not contain a dash; tags like v1.15.0-rc1 become 1.15.0~rc1,
# which rpm also orders correctly (a ~suffix sorts *before* the release).
RPM_VERSION="${VERSION#v}"
RPM_VERSION="${RPM_VERSION//-/\~}"

TOP="$(mktemp -d)"
trap 'rm -rf "$TOP"' EXIT
STAGE="$TOP/stage"

install -d \
  "$STAGE/opt/chess-auto-prep" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/128x128/apps" \
  "$STAGE/usr/share/metainfo"

cp -a "$BUNDLE"/. "$STAGE/opt/chess-auto-prep/"
ln -s /opt/chess-auto-prep/chess_auto_prep "$STAGE/usr/bin/chess_auto_prep"
install -m644 "$ROOT/linux/$APP_ID.desktop" "$STAGE/usr/share/applications/"
install -m644 "$ROOT/linux/$APP_ID.png" \
  "$STAGE/usr/share/icons/hicolor/128x128/apps/"
install -m644 "$ROOT/packaging/flatpak/$APP_ID.metainfo.xml" \
  "$STAGE/usr/share/metainfo/"

# AutoReqProv is off on purpose. The bundle carries its own boost_fiber, TBB,
# jemalloc and snappy next to libcdbdirect.so (see the $ORIGIN rpath step in
# release.yml); letting rpm scan them would generate Requires for Debian-built
# sonames that no Fedora repo provides, and the package would refuse to
# install. The four lines below are the real, host-supplied dependencies.
cat > "$TOP/chess-auto-prep.spec" <<SPEC
%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           chess-auto-prep
Version:        $RPM_VERSION
Release:        1
Summary:        Chess repertoire and tactics trainer
License:        AGPL-3.0-or-later
URL:            https://github.com/Zinkelburger/Chess-Auto-Prep
BuildArch:      x86_64
AutoReqProv:    no
Requires:       gtk3
Requires:       glib2
Requires:       libstdc++
Requires:       zlib

%description
Builds and trains opening repertoires, finds tactics in your own games,
analyses positions with Stockfish, and opens PGN files.

%install
cp -a $STAGE/. %{buildroot}/

%files
/opt/chess-auto-prep
/usr/bin/chess_auto_prep
/usr/share/applications/$APP_ID.desktop
/usr/share/icons/hicolor/128x128/apps/$APP_ID.png
/usr/share/metainfo/$APP_ID.metainfo.xml
SPEC

rpmbuild -bb \
  --define "_topdir $TOP" \
  --define "_rpmdir $TOP/RPMS" \
  --define "_build_id_links none" \
  "$TOP/chess-auto-prep.spec"

mkdir -p "$OUT"
mv "$TOP/RPMS/x86_64/chess-auto-prep-$RPM_VERSION-1.x86_64.rpm" \
   "$OUT/chess-auto-prep-$VERSION-linux-x86_64.rpm"
