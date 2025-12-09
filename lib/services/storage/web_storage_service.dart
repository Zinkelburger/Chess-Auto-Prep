import 'package:shared_preferences/shared_preferences.dart';
import 'storage_service.dart';

StorageService getStorageService() => WebStorageService();

class WebStorageService implements StorageService {
  static const String _tacticsCsvKey = 'tactics_positions_csv';
  static const String _analyzedGamesKey = 'analyzed_game_ids';
  static const String _importedGamesKey = 'imported_games_pgn';
  static const String _repertoirePrefix = 'repertoire_';

  @override
  Future<String?> readTacticsCsv() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tacticsCsvKey);
  }

  @override
  Future<void> saveTacticsCsv(String csvContent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tacticsCsvKey, csvContent);
  }

  @override
  Future<List<String>> readAnalyzedGameIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_analyzedGamesKey) ?? [];
  }

  @override
  Future<void> saveAnalyzedGameIds(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_analyzedGamesKey, ids);
  }

  @override
  Future<String?> readImportedPgns() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_importedGamesKey);
  }

  @override
  Future<void> saveImportedPgns(String pgnContent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_importedGamesKey, pgnContent);
  }

  @override
  Future<String?> readRepertoirePgn(String filename) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _repertoirePrefix + filename.replaceAll(RegExp(r'[^\w]'), '_');
    return prefs.getString(key);
  }

  @override
  Future<void> saveRepertoirePgn(String filename, String content) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _repertoirePrefix + filename.replaceAll(RegExp(r'[^\w]'), '_');
    await prefs.setString(key, content);
  }
}
