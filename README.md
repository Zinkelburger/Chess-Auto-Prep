# Chess Auto Prep - Flutter Edition

A cross-platform chess app: opening repertoire builder/trainer, tactics, position analysis, and PGN viewer.

## Features

- **Repertoire Builder**: Edit PGN, browse candidates, generate expectimax trees, traps, coverage
- **Repertoire Trainer**: Spaced-repetition training on your lines
- **Tactics Trainer**: Practice chess tactics from Lichess games
- **Position Analysis**: Analyze weak positions from your games
- **PGN Viewer**: Load and navigate through chess games
- **Engine Tournament**: Engine-vs-engine matches from any position, with a crosstable and PGN output — the one place you can point the app at your own UCI binary
- **Cross-platform desktop**: Runs on Linux, Windows, and macOS

## Documentation

Current implementation map: **[docs/COMPONENT_MAP.md](docs/COMPONENT_MAP.md)**  
Engine-vs-engine matches (in the app, headless, or from an agent): [docs/ENGINE_TOURNAMENT.md](docs/ENGINE_TOURNAMENT.md)  
Planned / incomplete work: [docs/FUTURE_FEATURES.md](docs/FUTURE_FEATURES.md)
Running the local CI gates and driving the app from a script (agents and humans): `scripts/ci.sh` and [.claude/skills/run-chess-auto-prep/SKILL.md](.claude/skills/run-chess-auto-prep/SKILL.md)

## Installing a release

Grab the file for your system from the
[latest release](https://github.com/Zinkelburger/Chess-Auto-Prep/releases/latest):

| System | File | Notes |
|---|---|---|
| Windows | `…-windows-setup.exe` | Recommended. Installs the app for your user, adds a Start Menu entry, and opens `.pgn` files. Unsigned, so SmartScreen warns once: **More info → Run anyway**. |
| Windows (portable) | `…-windows.zip` | No installer or admin access. Unzip anywhere and run; required runtime DLLs stay beside the app. |
| Debian / Ubuntu / Mint | `…-linux-amd64.deb` | Double-click, or `sudo apt install ./chess-auto-prep-*.deb`. |
| Fedora / RHEL / openSUSE | `…-linux-x86_64.rpm` | Double-click, or `sudo dnf install ./chess-auto-prep-*.rpm`. |
| Other Linux | `…-linux.flatpak` | Double-click, or `flatpak install chess-auto-prep-*.flatpak`. |
| Linux (portable) | `…-linux.zip` | Unzip and run. The app offers to add itself to your menu and take over `.pgn` files. |
| macOS | `…-macos-arm64.zip` / `…-macos-x86_64.zip` | Apple Silicon / Intel. Unsigned: right-click → Open the first time. |

Every install registers the app for `.pgn` files, so double-clicking a game
file opens it in the PGN viewer — in the window that is already open, if
there is one. Windows and most Linux desktops still ask you to confirm the
first time if another app already owns `.pgn`.

On a Windows PC that does not already have a recent Microsoft Visual C++
Runtime, Setup shows a **Required Microsoft component** page. Continue and
accept the one Windows permission prompt whose verified publisher is
**Microsoft Corporation**. The app itself still installs without elevation;
only Microsoft's signed, offline prerequisite asks for it. Cancel if that
prompt names any other publisher. Setup then verifies the runtime before it
installs or launches Chess Auto Prep, so there is no separate download or DLL
to find. The portable ZIP avoids this prompt by carrying its runtime locally.

Packaging lives in `packaging/` (`windows/installer.iss`, `deb/build_deb.sh`,
`rpm/build_rpm.sh`, `flatpak/`) and is driven by `.github/workflows/release.yml`
on `v*` tags. All Linux artifacts are x86_64: there is no arm64 build because
Stockfish ships no Linux arm64 binary and `libcdbdirect` has no arm64 target.

## Getting Started

### Prerequisites

- Flutter SDK 3.47.2 (the version pinned by CI)
- Dart SDK bundled with that Flutter release

### Installation

1. Clone the repository
```bash
git clone <repository-url>
cd Chess-Auto-Prep
```

2. Install Dart/Flutter packages
```bash
flutter pub get
```

3. Stockfish (optional — see [Binary assets](#binary-assets))
```bash
python3 tools/fetch_assets.py   # this machine only; `flutter run` also fetches if missing
```

4. Run
```bash
flutter run
```

Maia needs no extra step: the ONNX model is in git, and ONNX Runtime is a Flutter plugin.

## Binary assets

Two engines ship in the app: **Stockfish** (UCI process) and **Maia** (ONNX).
They are installed differently because only one has an upstream download.

### Stockfish (fetched, then bundled)

Not tracked in git (Linux+Windows+macOS is ~217 MB). `tools/fetch_assets.py`
downloads the pinned upstream build for **this machine only** (~75 MB gzipped).

| How you run | What happens |
|-------------|--------------|
| `python3 tools/fetch_assets.py` | Explicit installer. Puts `assets/executables/*.gz` so the next `flutter run` / `flutter build` bundles it. |
| `flutter run` / `flutter build` on Linux or Windows | CMake configure runs the same script if the `.gz` is missing. |
| `flutter run` on macOS | Xcode Assemble fetches the **host** engine only if `stockfish-macos.gz` is missing (so CI’s Intel job cannot overwrite a pre-fetched x86_64 binary). |
| Engine starts with no bundled `.gz` | The app downloads the lockfile URL into the support dir (first use, needs network). |
| GitHub Release zip | CI fetched the matching OS/arch before `flutter build`, so users do not download Stockfish. |

```bash
python3 tools/fetch_assets.py           # host OS/arch only
python3 tools/fetch_assets.py --check   # verify that asset; non-zero if missing
python3 tools/fetch_assets.py --force   # re-download and overwrite
python3 tools/fetch_assets.py --only stockfish-macos-arm64
```

Checksums live in `tools/assets.lock.json` (also a Flutter asset so the
in-app download can verify). Commit it when versions change.

### Maia (in git + plugin)

`assets/maia3_simplified.onnx` (~44 MB) **is** tracked: it is a local export
with no upstream file to fetch. Vocab JSON next to it is tiny and also
tracked. Native ONNX Runtime (`.so` / `.dll` / universal `.dylib`) comes from
the `onnxruntime` Flutter plugin and is copied into each desktop bundle
automatically — including both macOS architectures, which `ditto --arch`
thins per zip.

See [Regenerating the Maia model](#regenerating-the-maia-model).

> **Stockfish must be on disk before a *release* `flutter build` if you want
> it inside the zip** (CI does this). A local `flutter run` without the
> installer still works: the first engine use downloads it.

### Upgrading Stockfish

Pinned to `sf_18` in `tools/fetch_assets.py`. Tracking "latest" would make builds
non-reproducible and let an upstream release break the app with no commit to
point at. To upgrade: bump `STOCKFISH_TAG`, run with `--force`, verify the app
still starts, and commit the regenerated `assets.lock.json` alongside.

The pinned builds are **CPU-baseline** (`stockfish-ubuntu-x86-64` etc.). Faster
`-avx2` / `-bmi2` variants exist, but a binary built for an instruction set the
user's CPU lacks dies with `SIGILL` at startup, so baseline is the right default
for a shipped app.

### macOS downloads (Apple Silicon vs Intel)

GitHub Releases ship **two** macOS zips, not one universal/fat app:

| File | Machine | Stockfish inside `stockfish-macos.gz` |
|------|---------|----------------------------------------|
| `*-macos-arm64.zip` | M1 / M2 / M3 / M4 | `stockfish-macos-m1-apple-silicon` |
| `*-macos-x86_64.zip` | Intel | `stockfish-macos-x86-64` |

The app still has a single `stockfish-macos` slot; each zip is built with only
that architecture's Flutter binary and engine, so the download stays about half
the size of a universal bundle.

### Regenerating the Maia model

`assets/maia3_simplified.onnx` has **no upstream equivalent to download**.
Upstream [CSSLab/maia3](https://github.com/CSSLab/maia3) publishes PyTorch
checkpoints on Hugging Face (`UofTCSSLab/Maia3-{3M,5M,23M,79M}`, see
`maia3/model_registry.py`) and ships no ONNX at all. Our file is a local
`torch.onnx.export` + [onnx-simplifier](https://github.com/daquexian/onnx-simplifier)
artifact. There is nothing to download, which is why it stays in git while
Stockfish does not.

The original export did not record its checkpoint or opset, so byte-for-byte
regeneration is not honestly possible from the repository. Its provenance,
runtime tensor contract, sizes, and checksums are now recorded in
`tools/maia_model.lock.json`; `python3 tools/verify_maia_model.py` verifies the
model and both vocabulary files. Any future re-export must record the checkpoint
and opset and update that lock file in the same change.

### Local ChessDB (1 TB TerarkDB dump, Linux)

After building the cdbdirect reader in `tree_builder/`:

```bash
cd tree_builder && make setup-cdbdirect
cd ..
./run_with_cdbdirect.sh
```

In the app: **Repertoire → Actions → Database Downloads → Local ChessDB (full dump)** — browse to your `data/` directory (the folder containing `CURRENT` and `.sst` files).

See [tree_builder/CDBDIRECT_SETUP.md](tree_builder/CDBDIRECT_SETUP.md) for download and troubleshooting.

### Building for Different Platforms

Fetch Stockfish for the target first (`python3 tools/fetch_assets.py`, or
`--only` for a cross-build). Then:

- **Linux**: `flutter build linux`
- **Windows**: `flutter build windows`
- **macOS**: `flutter build macos`

macOS release artifacts are split by architecture in CI (see
[macOS downloads](#macos-downloads-apple-silicon-vs-intel)). A local
`flutter build macos` still produces whatever Xcode emits on this machine.

### Linux (KDE Wayland) app icon

On KDE Wayland, the window/taskbar icon comes from a `.desktop` file, not GTK. To show the knook icon in the title bar and taskbar, run once:

```bash
./install_linux_desktop.sh
```

Then restart the app (`flutter run -d linux`).

## Architecture

- **State Management**: Provider pattern
- **UI**: Material Design 3
- **Chess Logic**: chess package
- **Board Display**: flutter_chess_board
- **File Handling**: file_picker

## Key Components

- `lib/main.dart` - App entry point
- `lib/core/app_state.dart` - Global app state
- `lib/screens/main_screen.dart` - Main navigation
- `lib/widgets/` - UI components
- `lib/services/` - Business logic
- `lib/models/` - Data models

## Repository layout

The Flutter app is `lib/` + `assets/` + the platform runner dirs. Most other
trees here are **separate programs the app does not ship**. `tools/fetch_assets.py`
is the exception: it is a build step that fills gitignored Stockfish binaries.

| Path | What it is | Needed to run the app? |
|------|-----------|------------------------|
| `lib/`, `assets/`, `linux/`, `macos/`, `windows/` | The Flutter app itself | **Yes** |
| `packages/cdbdirect_flutter_libs/` | Native ChessDB FFI bindings, consumed via `pubspec.yaml` | Yes (built with the app) |
| `tree_builder/` | **Standalone C program.** The original prototype and reference implementation of the expectimax algorithm — since ported to Dart in `lib/services/generation/`. Also hosts the cdbdirect (local ChessDB) native build. | No — *except* its `make setup-cdbdirect` step, if you want the local 1 TB ChessDB dump. See [tree_builder/README.md](tree_builder/README.md). |
| `python/twic-position-finder/` | **Separate web service.** TWIC Position Finder — the live site + API behind `api.chessautoprep.com` (FastAPI backend, Astro frontend, weekly ingest cron, lesson booking). Deployed on its own. | No |
| `scripts/` | One-off data/analysis scripts (chess.com titled-player stats, USCF mapping, epub/pdf game extraction) | No |
| `tools/fetch_assets.py` | Downloads the host Stockfish into `assets/executables/` (gitignored) | **Yes, before `flutter run` / `flutter build`** |
| `tools/` (other) | MCP server, API/perf harnesses | No |

## Configuration

Set your Lichess username in the app settings to load tactics from your games.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

AGPL-3.0 — see [LICENSE](LICENSE) for the full text.
