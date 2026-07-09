import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../utils/file_text_reader.dart';
import 'tactics_database.dart';
import 'tactics_pgn_codec.dart';
import 'storage/storage_factory.dart';

import 'tactics_export_import_stub.dart'
    if (dart.library.io) 'tactics_export_import_io.dart' as platform;

/// Export file format for a puzzle set.
enum TacticsExportFormat {
  /// Legacy: full 20-column CSV including review stats (the pre-PGN
  /// storage format, kept for older tooling).
  csv,

  /// The native set format: one PGN game per puzzle (FEN + solution
  /// mainline + note), with stats and provenance as custom headers.
  /// Lossless, human-readable, and viewable in any chess GUI.
  pgn,
}

/// Result of an import: how many puzzles were added and any per-game
/// warnings (PGN games that could not be parsed, duplicates, ...).
typedef TacticsImportResult = ({int imported, List<String> warnings});

/// Service for exporting/importing tactics on supported native platforms.
/// Addresses the limitation that mobile users can't directly access app files
class TacticsExportImport {
  final TacticsDatabase _database;

  TacticsExportImport(this._database);

  /// Read the active set's raw file content from storage.
  Future<String?> _readActiveSetFile() async {
    final storage = StorageFactory.instance;
    return storage
        .readFile(await storage.tacticsSetPath(_database.activeSetName));
  }

  /// Export the active set to a file that users can share/save.
  /// On mobile: opens the share sheet.  On desktop: save-file picker.
  Future<void> exportTactics({
    TacticsExportFormat format = TacticsExportFormat.pgn,
  }) async {
    try {
      final setName = _database.activeSetName;
      if (_database.positions.isEmpty) {
        throw Exception('No tactics data to export');
      }
      final String content;
      final String filename;

      switch (format) {
        case TacticsExportFormat.csv:
          content = TacticsDatabase.encodeCsv(_database.positions);
          filename = '$setName.csv';
        case TacticsExportFormat.pgn:
          final result = encodePuzzlesToPgn(setName, _database.positions);
          if (result.encoded == 0) {
            throw Exception('No exportable puzzles in this set');
          }
          content = result.pgn;
          filename = '$setName.pgn';
      }

      await platform.exportContent(
        content,
        filename,
        _database.positions.length,
      );
    } catch (e) {
      debugPrint('Error exporting tactics: $e');
      rethrow;
    }
  }

  /// Import puzzles from a CSV or PGN file into the active set.
  ///
  /// Default is merge (FEN-deduped via [TacticsDatabase.addPositions]).
  /// With [replace] the set's contents are replaced instead.
  Future<TacticsImportResult> importTactics({bool replace = false}) async {
    try {
      // Keep withData enabled so file content is always available from picker.
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'pgn'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return (imported: 0, warnings: const <String>[]);
      }

      final file = result.files.first;

      // Use bytes (available on all platforms with withData: true)
      String content;
      if (file.bytes != null) {
        content = decodeTextBytes(file.bytes!);
      } else {
        throw Exception('Could not read file content');
      }

      final isPgn = (file.extension ?? '').toLowerCase() == 'pgn' ||
          content.trimLeft().startsWith('[');

      if (isPgn) {
        return _importPgn(content, replace: replace);
      }
      return _importCsv(content, replace: replace);
    } catch (e) {
      debugPrint('Error importing tactics: $e');
      rethrow;
    }
  }

  Future<TacticsImportResult> _importCsv(String csvContent,
      {required bool replace}) async {
    // Parse rows through the tolerant CSV path (the set file itself is PGN).
    final parsed = TacticsDatabase.parseCsv(csvContent);
    if (replace) {
      await _database.importAndSave(parsed.positions);
      return (imported: parsed.positions.length, warnings: parsed.warnings);
    }

    final before = _database.positions.length;
    await _database.addPositions(parsed.positions);
    return (
      imported: _database.positions.length - before,
      warnings: parsed.warnings,
    );
  }

  Future<TacticsImportResult> _importPgn(String pgnContent,
      {required bool replace}) async {
    final decoded = decodePuzzlesFromPgn(pgnContent);
    if (replace) {
      await _database.importAndSave(decoded.puzzles);
      return (imported: decoded.puzzles.length, warnings: decoded.errors);
    }
    final before = _database.positions.length;
    await _database.addPositions(decoded.puzzles);
    return (
      imported: _database.positions.length - before,
      warnings: decoded.errors,
    );
  }

  /// Get statistics about stored tactics
  Future<Map<String, dynamic>> getTacticsStats() async {
    final csvContent = await _readActiveSetFile();
    final fileExists = csvContent != null && csvContent.isNotEmpty;

    final stats = <String, dynamic>{
      'file_exists': fileExists,
      'storage_type': 'file',
      'positions_count': _database.positions.length,
      'total_reviews': _database.positions.fold<int>(
        0,
        (sum, pos) => sum + pos.reviewCount,
      ),
      'average_success_rate': _database.positions.isEmpty
          ? 0.0
          : _database.positions
                  .map((p) => p.successRate)
                  .reduce((a, b) => a + b) /
              _database.positions.length,
    };

    if (fileExists) {
      stats['content_size_bytes'] = csvContent.length;
    }

    return stats;
  }

  /// Clear all tactics data in the active set (useful for testing)
  Future<void> clearAllTactics() async {
    // Save empty content to clear the data
    final storage = StorageFactory.instance;
    await storage.writeFile(
        await storage.tacticsSetPath(_database.activeSetName), '');
    _database.positions.clear();
  }
}
