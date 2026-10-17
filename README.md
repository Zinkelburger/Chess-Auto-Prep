# Chess Auto Prep

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

[Mode specs](docs/features/README.md) · [Technical documentation](docs/COMPONENT_MAP.md) · [License: AGPL-3.0](LICENSE)

## Development and release checks

[.fvmrc](.fvmrc) pins Flutter for every workflow and the local Dart checks.
Use that SDK (or set `FLUTTER=/path/to/flutter/bin/flutter`).
`scripts/ci.sh lint` checks formatting without changing files;
`scripts/ci.sh format` is the separate command that applies formatting.
`scripts/ci.sh full` also checks formatting without applying fixes.

Before tagging, commit the final release candidate and run
`scripts/ci.sh preflight` in its clean checkout. This checks the SDK,
dependencies, formatting, analysis and unit/widget tests. It records
the commit and rejects uncommitted/untracked files or a changed HEAD at the end.
Inspect `build/quality-gates/summary.md` and the per-gate logs on failure;
GitHub retains required check logs in `flutter-quality-results` and formatting
logs in `advisory-housekeeping`.

Push the matching `v*` tag to release. The [Release workflow](.github/workflows/release.yml)
automatically runs offline tests, desktop integration, engine checks, both native
Mac builds, the Windows installer and five Linux package formats. Builds run
alongside tests, so a test failure cannot hide the next packaging failure. Once
all required gates pass, the same run validates all nine downloads, generates
`SHA256SUMS` and publishes the GitHub release. No separate rehearsal is required.
The `windows-check` branch remains an optional focused Windows diagnostic.
After a failed release, use a new version and tag rather than moving an existing tag.

The [advisory jobs](.github/workflows/release-advisory.yml) separately report
formatting, agent-rule consistency, and the process-kill crash-recovery test on
Windows 2022, Windows 2025 and macOS. Failures produce warnings and retained logs;
publication neither waits for these jobs nor requires them to pass. Local lint
and preflight remain strict. Analysis, the full Linux test suite (including crash
recovery), other desktop storage/integration tests, updater checks, offline tools,
engines and packaged-app checks remain required.

Only a `v*` **tag push** can enter the publication job, and only after every required gate
and artifact check passes. Diagnostic artifacts stay in Actions. Only the
publication job has write access; actions are pinned to commits and Dependabot
proposes weekly updates. Each Mac release bundle is checked in its packaging
job.

Stockfish 19 stores the Intel network data in the arm64 slice of its universal
executable ([upstream implementation](https://github.com/official-stockfish/Stockfish/blob/sf_19/src/universal/patch_x86_slice.sh)).
The app and frameworks may be thinned; the signed Stockfish helper must retain
both slices. Signing repacks those slices, so packaging preserves the complete
helper, rebases the Intel network pointer against the signed layout, verifies
every network byte against the pinned input, then signs again and checks that
the layout is stable. Both architectures are asserted before running the
packaged app on its native runner.
