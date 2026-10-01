# Chess Auto Prep

The renewal app (v2) is now the only implementation: run `lib/main.dart`.
V1 source has been retired; existing Documents and Support files stay in place.

A desktop chess app for building and practicing opening repertoires, reviewing
PGN games, analyzing positions, and training tactics. Runs on Windows, Linux,
and macOS. Stockfish and Maia are included.

## Install

Download your system’s file from the **[latest release](https://github.com/Zinkelburger/Chess-Auto-Prep/releases/latest)**:

| System | File ending |
|---|---|
| Windows | `windows-setup.exe` |
| Debian / Ubuntu / Mint | `linux-amd64.deb` |
| Fedora / RHEL / openSUSE | `linux-x86_64.rpm` |
| Other Linux | `linux-x86_64.AppImage` |
| macOS — Apple Silicon | `macos-arm64.zip` |
| macOS — Intel | `macos-x86_64.zip` |

Open the installer, or extract the macOS ZIP and open the app. To run the
AppImage, allow it to run as a program (right-click → Properties, or
`chmod +x`) and double-click it. Linux downloads require an x86_64 computer.
Portable ZIPs are also available for Windows and Linux, and a Flatpak that
updates only by hand.

The app is unsigned: Windows may require **More info → Run anyway**;
on macOS, right-click the app and choose **Open** the first time.

## Use

Open a PGN file to review games, or create a repertoire to build and practice
your opening lines. Set your Lichess username in Settings to load tactics from
your games.

The app checks GitHub for new versions and offers to update now or when you
close it (Windows installer, AppImage, .deb, .rpm and the Linux ZIP). Update
options are under **Settings → App**. The Flatpak, macOS and the Windows ZIP
update from the release page. Keep backups of important work before upgrading.

[Technical documentation](docs/COMPONENT_MAP.md) · [License: AGPL-3.0](LICENSE)

## Development and release checks

[.fvmrc](.fvmrc) pins Flutter for every workflow and the local Dart checks.
Use that SDK (or set `FLUTTER=/path/to/flutter/bin/flutter`).
`scripts/ci.sh lint` checks formatting without changing files;
`scripts/ci.sh format` is the separate command that applies formatting.
`scripts/ci.sh full` also checks formatting without applying fixes.

Before tagging, commit the final release candidate and run
`scripts/ci.sh preflight` in its clean checkout. This runs the same SDK,
dependency, formatting, analysis and unit/widget gates as release CI. It records
the commit and rejects uncommitted/untracked files or a changed HEAD at the end.
Inspect `build/quality-gates/summary.md` and the per-gate logs on failure;
GitHub retains these in `flutter-quality-results`, including formatting failures.
Tag only that validated commit, matching the version in `pubspec.yaml`; after a
failed release, use a new version and tag rather than moving an existing tag.

Preflight covers the shared Dart job. The release still requires the separate
offline-tool, desktop integration, engine, installer and platform build gates.
Publication accepts only the four named build artifacts, verifies all eight
nonempty downloads, and generates `SHA256SUMS` for precisely those downloads.
Diagnostic artifacts stay in Actions. Only the publication job has write access;
actions are pinned to commits and Dependabot proposes weekly updates.
