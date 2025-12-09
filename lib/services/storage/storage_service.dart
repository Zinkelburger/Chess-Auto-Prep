import 'dart:async';

/// Abstract interface for storage operations
abstract class StorageService {
  Future<String?> readTacticsCsv();
  Future<void> saveTacticsCsv(String csvContent);
  
  Future<List<String>> readAnalyzedGameIds();
  Future<void> saveAnalyzedGameIds(List<String> ids);
  
  Future<String?> readImportedPgns();
  Future<void> saveImportedPgns(String pgnContent);
  
  Future<String?> readRepertoirePgn(String filename);
  Future<void> saveRepertoirePgn(String filename, String content);
}

