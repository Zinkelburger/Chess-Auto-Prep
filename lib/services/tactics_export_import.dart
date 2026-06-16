import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../utils/file_text_reader.dart';
import 'tactics_database.dart';
import 'storage/storage_factory.dart';

import 'tactics_export_import_stub.dart'
    if (dart.library.io) 'tactics_export_import_io.dart' as platform;

/// Service for exporting/importing tactics on supported native platforms.
/// Addresses the limitation that mobile users can't directly access app files
class TacticsExportImport {
  final TacticsDatabase _database;

  TacticsExportImport(this._database);

  /// Export tactics to a file that users can share/save
  /// On mobile: Opens share sheet
  /// On desktop: Opens file picker to choose save location
  Future<void> exportTactics() async {
    try {
      // Get the current CSV content
      final csvContent = await StorageFactory.instance.readTacticsCsv();

      if (csvContent == null || csvContent.isEmpty) {
        throw Exception('No tactics data to export');
      }

      await platform.exportCsvContent(
        csvContent,
        'tactics_positions_export.csv',
        _database.positions.length,
      );
    } catch (e) {
      debugPrint('Error exporting tactics: $e');
      rethrow;
    }
  }

  /// Import tactics from a CSV file.
  Future<int> importTactics() async {
    try {
      // Keep withData enabled so file content is always available from picker.
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return 0;
      }

      final file = result.files.first;

      // Use bytes (available on all platforms with withData: true)
      String content;
      if (file.bytes != null) {
        content = decodeTextBytes(file.bytes!);
      } else {
        throw Exception('Could not read file content');
      }

      // Parse and import positions
      final importedCount = await _importFromCsvContent(content);

      return importedCount;
    } catch (e) {
      debugPrint('Error importing tactics: $e');
      rethrow;
    }
  }

  Future<int> _importFromCsvContent(String csvContent) async {
    // Save the CSV content via StorageService
    await StorageFactory.instance.saveTacticsCsv(csvContent);

    // Reload from storage
    final count = await _database.loadPositions();

    return count;
  }

  /// Get statistics about stored tactics
  Future<Map<String, dynamic>> getTacticsStats() async {
    final csvContent = await StorageFactory.instance.readTacticsCsv();
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

  /// Clear all tactics data (useful for testing)
  Future<void> clearAllTactics() async {
    // Save empty content to clear the data
    await StorageFactory.instance.saveTacticsCsv('');
    _database.positions.clear();
  }
}
