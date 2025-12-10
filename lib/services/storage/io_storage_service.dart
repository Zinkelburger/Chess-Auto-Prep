import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'storage_service.dart';

StorageService getStorageService() => IOStorageService();

class IOStorageService implements StorageService {
  static const String _tacticsCsvFileName = 'tactics_positions.csv';
  static const String _analyzedGamesFileName = 'analyzed_games.txt';
  static const String _importedGamesFileName = 'imported_games.pgn';
  static const String _repertoireReviewsFileName = 'repertoire_reviews.csv';
  static const String _repertoireReviewHistoryFileName = 'repertoire_review_history.csv';
  static const String _repertoireMoveProgressFileName = 'repertoire_move_progress.csv';

  Future<File> _getFile(String filename) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$filename');
  }

  @override
  Future<String?> readTacticsCsv() async {
    try {
      final file = await _getFile(_tacticsCsvFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      print('Error reading tactics CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveTacticsCsv(String csvContent) async {
    try {
      final file = await _getFile(_tacticsCsvFileName);
      await file.writeAsString(csvContent);
    } catch (e) {
      print('Error saving tactics CSV: $e');
    }
  }

  @override
  Future<List<String>> readAnalyzedGameIds() async {
    try {
      final file = await _getFile(_analyzedGamesFileName);
      if (await file.exists()) {
        final content = await file.readAsString();
        return content.split('\n').where((id) => id.trim().isNotEmpty).toList();
      }
    } catch (e) {
      print('Error reading analyzed game IDs: $e');
    }
    return [];
  }

  @override
  Future<void> saveAnalyzedGameIds(List<String> ids) async {
    try {
      final file = await _getFile(_analyzedGamesFileName);
      await file.writeAsString(ids.join('\n'));
    } catch (e) {
      print('Error saving analyzed game IDs: $e');
    }
  }

  @override
  Future<String?> readImportedPgns() async {
    try {
      final file = await _getFile(_importedGamesFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      print('Error reading imported PGNs: $e');
    }
    return null;
  }

  @override
  Future<void> saveImportedPgns(String pgnContent) async {
    try {
      final file = await _getFile(_importedGamesFileName);
      await file.writeAsString(pgnContent);
    } catch (e) {
      print('Error saving imported PGNs: $e');
    }
  }

  @override
  Future<String?> readRepertoirePgn(String filename) async {
    try {
      File file;
      if (filename.startsWith('/')) {
        file = File(filename);
      } else {
        file = await _getFile(filename);
      }
      
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      print('Error reading repertoire PGN: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoirePgn(String filename, String content) async {
    try {
      final file = await _getFile(filename);
      await file.writeAsString(content);
    } catch (e) {
      print('Error saving repertoire PGN: $e');
    }
  }

  @override
  Future<String?> readRepertoireReviewsCsv() async {
    try {
      final file = await _getFile(_repertoireReviewsFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      print('Error reading repertoire reviews CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoireReviewsCsv(String csvContent) async {
    try {
      final file = await _getFile(_repertoireReviewsFileName);
      await file.writeAsString(csvContent);
    } catch (e) {
      print('Error saving repertoire reviews CSV: $e');
    }
  }

  @override
  Future<String?> readRepertoireReviewHistoryCsv() async {
    try {
      final file = await _getFile(_repertoireReviewHistoryFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      print('Error reading repertoire review history CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoireReviewHistoryCsv(String csvContent) async {
    try {
      final file = await _getFile(_repertoireReviewHistoryFileName);
      await file.writeAsString(csvContent);
    } catch (e) {
      print('Error saving repertoire review history CSV: $e');
    }
  }

  @override
  Future<String?> readRepertoireMoveProgressCsv() async {
    try {
      final file = await _getFile(_repertoireMoveProgressFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      print('Error reading repertoire move progress CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoireMoveProgressCsv(String csvContent) async {
    try {
      final file = await _getFile(_repertoireMoveProgressFileName);
      await file.writeAsString(csvContent);
    } catch (e) {
      print('Error saving repertoire move progress CSV: $e');
    }
  }
}
