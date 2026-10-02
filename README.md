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

Local preflight covers the shared Dart job. Before tagging, push the candidate
commit to the deliberate rehearsal branch:

```sh
git push origin HEAD:refs/heads/release-check
```

The [Release workflow](.github/workflows/release.yml) runs the **same** offline
tests, desktop integration, engine checks, both native Mac builds, Windows
installer and five Linux package formats as a tag push. Builds run alongside
tests, so a test failure cannot hide the next packaging failure. It validates all nine
downloads and their `SHA256SUMS`, then saves `release-candidate` in Actions for
seven days. It publishes nothing. Inspect the `validate-assets` job summary for
the validated commit SHA; only tag that commit, with the version already in
`pubspec.yaml`. If any source changes, rehearse the new commit. After a failed
release, use a new version and tag rather than moving an existing tag. Do not
force-update a rehearsal branch belonging to somebody else's active candidate.

Once this workflow is on the default branch, a manual rehearsal can target any
pushed candidate branch with `gh workflow run release.yml --ref BRANCH`
([GitHub's manual-run documentation](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)).
Even a manual run against a tag cannot publish. The existing `windows-check`
branch remains a focused Windows diagnostic, not a complete release rehearsal.

Only a `v*` **tag push** can enter the publication job, and only after every gate
and artifact check passes. Diagnostic artifacts stay in Actions. Only the
publication job has write access; actions are pinned to commits and Dependabot
proposes weekly updates. Each Mac release bundle is checked in its packaging
job. The duplicate Apple Silicon release build and standalone Mac engine job
have been removed.

The failures that prompted this setup:

| Candidate | GitHub evidence | Cause and prevention |
|---|---|---|
| 2.0.0 | [Failed run](https://github.com/Zinkelburger/Chess-Auto-Prep/actions/runs/36754478934) | Linux fault tests found inconsistent book references after delete/restore and an interleaving timeout. Windows tests exposed directory-sync assumptions, a missing-warning assertion and a database handle left open during cleanup. These gates passed on 2.0.1; retain them and run them before tagging. |
| 2.0.1 | [Failed run](https://github.com/Zinkelburger/Chess-Auto-Prep/actions/runs/36931974043) | Intel Mac packaging rejected Stockfish's gzip checksum. The existing fix pins the uncompressed engine and uses a native Intel runner. A full rehearsal now exercises both Mac release builds, which a green Windows check did not cover. |
