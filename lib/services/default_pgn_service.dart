import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Extracts bundled PGN game collections from Flutter assets into the app's
/// documents directory on first launch, giving the PGN Viewer a default
/// library of classic player games to browse.
class DefaultPgnService {
  static const _extractedKey = 'pgn_collections_extracted';
  static const _directoryName = 'pgn_collections';

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
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, _directoryName);
  }

  /// Extracts bundled PGN assets to disk if not already done.
  /// Skips individual files that already exist so user deletions are respected.
  static Future<void> ensureExtracted() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_extractedKey) == true) return;

    final dir = Directory(await collectionsPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    for (final name in bundledFiles) {
      final target = File(p.join(dir.path, name));
      if (await target.exists()) continue;

      try {
        final data = await rootBundle.loadString('assets/$_directoryName/$name');
        await target.writeAsString(data, flush: true);
      } catch (e) {
        // Asset missing from bundle (e.g. stripped for size) — skip silently.
        print('Could not extract bundled PGN $name: $e');
      }
    }

    await prefs.setBool(_extractedKey, true);
  }

  /// Lists PGN files currently in the collections directory.
  static Future<List<File>> listCollections() async {
    final dir = Directory(await collectionsPath);
    if (!await dir.exists()) return [];

    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.pgn'))
        .cast<File>()
        .toList();

    files.sort((a, b) =>
        p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
    return files;
  }
}
