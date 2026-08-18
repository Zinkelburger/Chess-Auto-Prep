# Chess Auto Prep - Flutter Edition

A cross-platform chess app: opening repertoire builder/trainer, tactics, position analysis, and PGN viewer.

## Features

- **Repertoire Builder**: Edit PGN, browse candidates, generate expectimax trees, traps, coverage
- **Repertoire Trainer**: Spaced-repetition training on your lines
- **Tactics Trainer**: Practice chess tactics from Lichess games
- **Position Analysis**: Analyze weak positions from your games
- **PGN Viewer**: Load and navigate through chess games
- **Cross-platform**: Runs on iOS, Android, and Desktop

## Documentation

Current implementation map: **[docs/COMPONENT_MAP.md](docs/COMPONENT_MAP.md)**  
Planned / incomplete work: [docs/FUTURE_FEATURES.md](docs/FUTURE_FEATURES.md)

## Getting Started

### Prerequisites

- Flutter SDK (3.10.0 or higher)
- Dart SDK (3.0.0 or higher)

### Installation

1. Clone the repository
```bash
git clone <repository-url>
cd Chess-Auto-Prep
```

2. Install dependencies
```bash
flutter pub get
```

3. Fetch the binary assets (required — see [Binary assets](#binary-assets))
```bash
python3 tools/fetch_assets.py
```

4. Run the app
```bash
flutter run
```

## Binary assets

The three Stockfish engines (~217 MB) are **not tracked in git** — they are
fetched from the pinned upstream release on demand.

```bash
python3 tools/fetch_assets.py           # fetch anything missing (~217 MB, once)
python3 tools/fetch_assets.py --check   # verify presence; non-zero exit if missing
python3 tools/fetch_assets.py --force   # re-download and overwrite
```

The script is stdlib-only (no pip install), idempotent, and records upstream
checksums in `tools/assets.lock.json` — commit that file when versions change.

`assets/maia3_simplified.onnx` (46 MB) **is** tracked, and deliberately so: it
is a local export with no upstream to fetch from, so git is the only copy that
exists. See [Regenerating the Maia model](#regenerating-the-maia-model).

> **This is a build prerequisite, not just a dev convenience.** `pubspec.yaml`
> bundles `assets/executables/` and `assets/maia3_simplified.onnx` into the
> Flutter root bundle, and `lib/services/engine/process_connection.dart` loads
> them from there at runtime. Stockfish must be present *before* `flutter build`
> runs, including in CI. Add `python3 tools/fetch_assets.py --check` to your
> pipeline ahead of the build step to fail fast with a clear message.

### Upgrading Stockfish

Pinned to `sf_18` in `tools/fetch_assets.py`. Tracking "latest" would make builds
non-reproducible and let an upstream release break the app with no commit to
point at. To upgrade: bump `STOCKFISH_TAG`, run with `--force`, verify the app
still starts, and commit the regenerated `assets.lock.json` alongside.

The pinned builds are **CPU-baseline** (`stockfish-ubuntu-x86-64` etc.). Faster
`-avx2` / `-bmi2` variants exist, but a binary built for an instruction set the
user's CPU lacks dies with `SIGILL` at startup, so baseline is the right default
for a shipped app.

> **Open decision (macOS):** the app has a single `stockfish-macos` slot, so it
> gets the x86-64 build, which runs on Apple Silicon only via Rosetta 2 — not
> always installed, and being wound down by Apple. The native
> `stockfish-macos-m1-apple-silicon` build is far faster but will not run on
> Intel Macs. Shipping both requires teaching `process_connection.dart` to pick
> per-architecture.

### Regenerating the Maia model

`assets/maia3_simplified.onnx` has **no upstream equivalent to download**.
Upstream [CSSLab/maia3](https://github.com/CSSLab/maia3) publishes PyTorch
checkpoints on Hugging Face (`UofTCSSLab/Maia3-{3M,5M,23M,79M}`, see
`maia3/model_registry.py`) and ships no ONNX at all. Our file is a local
`torch.onnx.export` + [onnx-simplifier](https://github.com/daquexian/onnx-simplifier)
artifact. There is nothing to download, which is why it stays in git while
Stockfish does not.

**The export procedure is not currently checked in.** Until it is, the committed
file is the only source of truth — do not delete it, and do not strip it in a
history rewrite. If you re-export, add the script under `tools/` and record which
checkpoint and opset it used, so the model stops being an unreproducible binary.

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

- **Android**: `flutter build apk`
- **iOS**: `flutter build ios`
- **Desktop**: `flutter build windows/macos/linux`

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

The Flutter app is `lib/` + `assets/` + the platform runner dirs. Everything
else in this repo is a **separate program that the app does not build, ship, or
call at runtime**:

| Path | What it is | Needed to run the app? |
|------|-----------|------------------------|
| `lib/`, `assets/`, `linux/`, `macos/`, `windows/` | The Flutter app itself | **Yes** |
| `packages/cdbdirect_flutter_libs/` | Native ChessDB FFI bindings, consumed via `pubspec.yaml` | Yes (built with the app) |
| `tree_builder/` | **Standalone C program.** The original prototype and reference implementation of the expectimax algorithm — since ported to Dart in `lib/services/generation/`. Also hosts the cdbdirect (local ChessDB) native build. | No — *except* its `make setup-cdbdirect` step, if you want the local 1 TB ChessDB dump. See [tree_builder/README.md](tree_builder/README.md). |
| `python/twic-position-finder/` | **Separate web service.** TWIC Position Finder — the live site + API behind `api.chessautoprep.com` (FastAPI backend, Astro frontend, weekly ingest cron, lesson booking). Deployed on its own. | No |
| `scripts/` | One-off data/analysis scripts (chess.com titled-player stats, USCF mapping, epub/pdf game extraction) | No |
| `tools/` | Small API/perf benchmarking harnesses | No |

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