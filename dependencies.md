# Dependencies and Setup

## Linux Requirements

For proper file storage on Linux systems (especially immutable distros), you need:

### XDG User Directories
The app uses Flutter's `getApplicationDocumentsDirectory()` which requires XDG configuration:

```bash
# Install xdg-user-dirs
sudo dnf install xdg-user-dirs        # Fedora
sudo apt install xdg-user-dirs        # Ubuntu/Debian
sudo pacman -S xdg-user-dirs          # Arch

# Configure user directories
xdg-user-dirs-update
```

On Linux, the path_provider package doesn't just guess a path. It follows the standard set by the XDG Base Directory Specification.

### Verify Setup
```bash
xdg-user-dir DOCUMENTS
# Should output: /home/username/Documents (or similar)
```

## Flutter Dependencies

### Core Dependencies
- `path_provider: ^2.1.1` - Cross-platform paths
- `path_provider_linux: ^2.2.1` - Linux implementation
- `shared_preferences: ^2.5.3` - Settings storage

### Platform Support
- **Desktop**: Linux, Windows, macOS
- **Web**: localStorage fallback
- **Mobile**: Android, iOS (future)

## Packaging Options

### Flatpak
```bash
cd flatpak
./build.sh
flatpak install build org.chessautoprep.app
```

### Web Deployment
```bash
flutter build web --release
# Serve from build/web/
```

### Native Linux
```bash
flutter build linux --release
# Binary in build/linux/x64/release/bundle/
```

