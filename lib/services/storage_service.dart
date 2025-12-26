import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static StorageService? _instance;
  static StorageService get instance => _instance ??= StorageService._();

  StorageService._();

  Future<Directory> getStorageDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('File storage not supported on web platform. Use shared_preferences or IndexedDB instead.');
    }
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

  Future<void> saveContent(String filename, String content) async {
    if (kIsWeb) {
      throw UnsupportedError('StorageService.saveContent() is not supported on web. Use shared_preferences or IndexedDB instead.');
    }
    final file = await getStorageFile(filename);
    await file.writeAsString(content);
  }

  Future<String?> loadContent(String filename) async {
    if (kIsWeb) {
      throw UnsupportedError('StorageService.loadContent() is not supported on web. Use shared_preferences or IndexedDB instead.');
    }
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