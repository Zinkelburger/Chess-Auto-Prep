import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  // Unified save method
  Future<void> saveContent(String filename, String content) async {
    if (kIsWeb) {
      // Web storage handling removed for simplicity as it requires extra dependencies
      // or conditional imports which were causing issues.
      // Re-implement using shared_preferences if web support is needed.
      return;
    } else {
      final file = await getStorageFile(filename);
      await file.writeAsString(content);
    }
  }

  // Unified load method
  Future<String?> loadContent(String filename) async {
    if (kIsWeb) {
       // Web storage handling removed
       return null;
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