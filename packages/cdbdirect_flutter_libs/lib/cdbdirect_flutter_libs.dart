/// Bundles the cdbdirect native reader for ChessDB TerarkDB `.sst` dumps.
///
/// End users only need to point the app at their downloaded `data/` directory.
/// No env vars or setup scripts required when the platform library is bundled.
library cdbdirect_flutter_libs;

import 'dart:ffi';
import 'dart:io';

/// Whether this desktop OS is supported by the bundled reader.
bool get isDesktopPlatform =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Human-readable OS name for UI messages.
String get platformDisplayName {
  if (Platform.isLinux) return 'Linux';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  return Platform.operatingSystem;
}

/// Standard dynamic library file name for the current platform.
String get libraryFileName {
  if (Platform.isLinux) return 'libcdbdirect.so';
  if (Platform.isMacOS) return 'libcdbdirect.dylib';
  if (Platform.isWindows) return 'cdbdirect.dll';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Opens the bundled cdbdirect library, or `null` if it is not present.
///
/// Linux builds ship the bundled `.so` when CI has built it. Other desktop
/// platforms may add prebuilts later — callers must handle a `null` return.
DynamicLibrary? openLibrary() {
  if (!Platform.isLinux) return null;
  try {
    return DynamicLibrary.open(libraryFileName);
  } on ArgumentError {
    return null;
  } on OSError {
    return null;
  }
}

/// True when [openLibrary] succeeds (bundled or already on the loader path).
bool get isBundledLibraryAvailable => openLibrary() != null;
