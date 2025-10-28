#!/bin/bash

# Build script for Flatpak packaging

# Build Flutter app for Linux
echo "Building Flutter app for Linux..."
cd ..
flutter build linux --release

# Build Flatpak
echo "Building Flatpak..."
cd flatpak
flatpak-builder --force-clean build org.chessautoprep.app.yml

echo "Flatpak build complete!"
echo "To install: flatpak install build org.chessautoprep.app"
echo "To run: flatpak run org.chessautoprep.app"