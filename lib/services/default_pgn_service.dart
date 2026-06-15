import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/file_text_reader.dart';
import 'storage/app_paths.dart';

/// Extracts bundled PGN game collections from Flutter assets into the app's
/// documents directory on first launch, giving the PGN Viewer a default
/// library of classic player games to browse.
class DefaultPgnService {
  static const _extractedKey = 'pgn_collections_extracted';
  static const _directoryName = AppPaths.pgnCollectionsDirectoryName;

  static const List<String> bundledFiles = [
    'Capablanca.pgn',
    'Carlsen.pgn',
    'Fischer.pgn',
    'Kasparov.pgn',
    'Morphy.pgn',
    'Nakamura.pgn',
    'PolgarJ.pgn',
    'Tal.pgn',
  ];

  /// Returns the path to the pgn_collections directory under app documents.
  static Future<String> get collectionsPath async {
    final dir = await AppPaths.pgnCollectionsDirectory();
    return dir.path;
  }

  /// Extracts bundled PGN assets to disk if not already done.
  /// Skips individual files that already exist so user deletions are respected.
  static Future<void> ensureExtracted() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_extractedKey) == true) return;

    final dir = await AppPaths.pgnCollectionsDirectory(create: true);

    var hadExtractionFailure = false;

    for (final name in bundledFiles) {
      final target = File(p.join(dir.path, name));
      if (await target.exists()) continue;

      try {
        final byteData = await rootBundle.load('assets/$_directoryName/$name');
        final data = decodeTextBytes(byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ));
        await target.writeAsString(data, flush: true);
      } catch (e) {
        // Asset missing from bundle (e.g. stripped for size) — skip silently.
        debugPrint('Could not extract bundled PGN $name: $e');
        hadExtractionFailure = true;
      }
    }

    // Only mark extraction complete if this pass succeeded fully.
    if (!hadExtractionFailure) {
      await prefs.setBool(_extractedKey, true);
    }
  }

  /// Lists PGN files currently in the collections directory.
  static Future<List<File>> listCollections() async {
    final dir = await AppPaths.pgnCollectionsDirectory();
    if (!await dir.exists()) return [];

    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.pgn'))
        .cast<File>()
        .toList();

    files.sort((a, b) => p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase()));
    return files;
  }
}
