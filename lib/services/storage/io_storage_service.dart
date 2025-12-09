import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'storage_service.dart';

StorageService getStorageService() => IOStorageService();

class IOStorageService implements StorageService {
  static const String _tacticsCsvFileName = 'tactics_positions.csv';
  static const String _analyzedGamesFileName = 'analyzed_games.txt';
  static const String _importedGamesFileName = 'imported_games.pgn';

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
}
