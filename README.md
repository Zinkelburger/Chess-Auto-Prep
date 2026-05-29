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

3. Run the app
```bash
flutter run
```

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