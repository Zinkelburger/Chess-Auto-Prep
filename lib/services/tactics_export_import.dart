import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'tactics_database.dart';
import '../models/tactics_position.dart';

/// Service for exporting/importing tactics on mobile
/// Addresses the limitation that mobile users can't directly access app files
class TacticsExportImport {
  final TacticsDatabase _database;

  TacticsExportImport(this._database);

  /// Export tactics to a file that users can share/save
  /// On mobile: Opens share sheet
  /// On desktop: Opens file picker to choose save location
  Future<void> exportTactics() async {
    try {
      // Get the current CSV file
      final directory = await getApplicationDocumentsDirectory();
      final csvFile = File('${directory.path}/tactics_positions.csv');

      if (!await csvFile.exists()) {
        throw Exception('No tactics data to export');
      }

      // On mobile, use share sheet
      if (Platform.isAndroid || Platform.isIOS) {
        final result = await Share.shareXFiles(
          [XFile(csvFile.path)],
          subject: 'Chess Tactics - ${_database.positions.length} positions',
          text: 'Export of ${_database.positions.length} chess tactics positions',
        );

        if (result.status == ShareResultStatus.success) {
          print('Tactics exported successfully');
        }
      } else {
        // On desktop, let user choose save location
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Export Tactics',
          fileName: 'tactics_positions_export.csv',
          type: FileType.custom,
          allowedExtensions: ['csv'],
        );

        if (savePath != null) {
          final content = await csvFile.readAsString();
          await File(savePath).writeAsString(content);
          print('Tactics exported to: $savePath');
        }
      }
    } catch (e) {
      print('Error exporting tactics: $e');
      rethrow;
    }
  }

  /// Import tactics from a CSV file
  /// On mobile: Opens file picker
  /// On desktop: Opens file picker
  Future<int> importTactics() async {
    try {
      // Let user pick a CSV file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true, // Important for mobile to get file content
      );

      if (result == null || result.files.isEmpty) {
        return 0;
      }

      final file = result.files.first;

      // On mobile, we get bytes. On desktop, we get path.
      String content;
      if (file.bytes != null) {
        content = String.fromCharCodes(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        throw Exception('Could not read file');
      }

      // Parse and import positions
      final importedCount = await _importFromCsvContent(content);

      return importedCount;
    } catch (e) {
      print('Error importing tactics: $e');
      rethrow;
    }
  }

  Future<int> _importFromCsvContent(String csvContent) async {
    // This would parse the CSV and add to database
    // For now, just replace the existing CSV file
    final directory = await getApplicationDocumentsDirectory();
    final csvFile = File('${directory.path}/tactics_positions.csv');

    await csvFile.writeAsString(csvContent);

    // Reload from file
    final count = await _database.loadPositions();

    return count;
  }

  /// Get statistics about stored tactics
  Future<Map<String, dynamic>> getTacticsStats() async {
    final directory = await getApplicationDocumentsDirectory();
    final csvFile = File('${directory.path}/tactics_positions.csv');

    final stats = {
      'file_exists': await csvFile.exists(),
      'file_path': csvFile.path,
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

    if (await csvFile.exists()) {
      final fileStat = await csvFile.stat();
      stats['file_size_bytes'] = fileStat.size;
      stats['last_modified'] = fileStat.modified.toIso8601String();
    }

    return stats;
  }

  /// Clear all tactics data (useful for testing)
  Future<void> clearAllTactics() async {
    final directory = await getApplicationDocumentsDirectory();
    final csvFile = File('${directory.path}/tactics_positions.csv');

    if (await csvFile.exists()) {
      await csvFile.delete();
    }

    _database.positions.clear();
  }
}
