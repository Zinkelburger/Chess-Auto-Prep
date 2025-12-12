# Chess Auto Prep - Flutter Edition

A cross-platform chess tactics trainer and PGN analyzer built with Flutter.

## Features

- **Tactics Trainer**: Practice chess tactics from Lichess games
- **Position Analysis**: Analyze weak positions from your games
- **PGN Viewer**: Load and navigate through chess games
- **Cross-platform**: Runs on iOS, Android, Web, and Desktop

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

### Building for Different Platforms

- **Android**: `flutter build apk`
- **iOS**: `flutter build ios`
- **Web**: `flutter build web`
- **Desktop**: `flutter build windows/macos/linux`

## Deploying to Cloudflare Pages

Cloudflare Pages can serve the Flutter web build without a separate host. Two options are available:

**Recommended: GitHub Actions (direct build + deploy with Wrangler)**

1. In the repository settings, add secrets:
   - `CLOUDFLARE_ACCOUNT_ID`: your Cloudflare account ID
   - `CLOUDFLARE_API_TOKEN`: API token with “Cloudflare Pages:Edit” (or Pages write) scope for that account
2. Adjust the project name in `.github/workflows/deploy-cloudflare-pages.yml` if you want something other than the default `chess-auto-prep`.
3. Push to `main` → production deploy. PRs against `main` → preview deploys. Concurrency is enabled to cancel superseded runs, and the Flutter SDK is cached for faster builds.
4. If you prefer the Pages UI integration instead of Actions, you can connect the repo directly and keep the same build command (`flutter build web --release`) and output directory (`build/web`).

Optional (faster runtime via Wasm, Flutter 3.22+): switch the build command to `flutter build web --wasm --release` and add `web/_headers`:
```
/*
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
```
This enables cross-origin isolation needed for Wasm shared memory.

**Alternative: Peanut branch-based deploy (from the referenced blog)**

1. Install peanut: `flutter pub global activate peanut`
2. Build and export the web release to a branch (defaults to `production`): `flutter pub global run peanut -b production`
3. Push the branch: `git push origin production`
4. In Cloudflare Pages, point the project at the branch you exported and set:
   - Production branch: `production` (or your chosen branch)
   - Build command: None (the branch already contains the built site)
   - Output directory: `.`

You can target a different Pages branch by setting `CLOUDFLARE_PAGES_BRANCH=<branch>` before running `scripts/deploy_cloudflare_pages.sh`; it will push to the matching branch so Cloudflare can deploy preview environments.

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