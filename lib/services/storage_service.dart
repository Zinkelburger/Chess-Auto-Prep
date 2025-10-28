import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
// Conditional import for web
import 'storage_web.dart' if (dart.library.io) 'storage_io.dart' as platform;

class StorageService {
  static StorageService? _instance;
  static StorageService get instance => _instance ??= StorageService._();

  StorageService._();

  Future<Directory> getStorageDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('File storage not supported on web platform');
    }

    // Use proper Flutter path_provider approach
    // This now works correctly with xdg-user-dirs installed
    return await getApplicationDocumentsDirectory();
  }

  Future<String> getStoragePath(String filename) async {
    final directory = await getStorageDirectory();
    return '${directory.path}/$filename';
  }

  Future<File> getStorageFile(String filename) async {
    final path = await getStoragePath(filename);
    return File(path);
  }

  // Web-specific storage methods using localStorage
  Future<void> saveToWeb(String key, String content) async {
    if (!kIsWeb) return;
    platform.PlatformStorage.saveToLocalStorage(key, content);
  }

  Future<String?> loadFromWeb(String key) async {
    if (!kIsWeb) return null;
    return platform.PlatformStorage.loadFromLocalStorage(key);
  }

  // Unified save method that works on all platforms
  Future<void> saveContent(String filename, String content) async {
    if (kIsWeb) {
      await saveToWeb(filename, content);
    } else {
      final file = await getStorageFile(filename);
      await file.writeAsString(content);
    }
  }

  // Unified load method that works on all platforms
  Future<String?> loadContent(String filename) async {
    if (kIsWeb) {
      return await loadFromWeb(filename);
    } else {
      try {
        final file = await getStorageFile(filename);
        if (await file.exists()) {
          return await file.readAsString();
        }
        return null;
      } catch (e) {
        return null;
      }
    }
  }
}