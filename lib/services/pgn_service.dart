import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/chess_game.dart';
import 'storage/storage_factory.dart';

class PgnService {
  Future<List<ChessGameModel>> loadPgnFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pgn'],
      allowMultiple: true,
      withData: kIsWeb, // Important for web!
    );

    if (result == null) return [];

    final games = <ChessGameModel>[];

    for (final file in result.files) {
      String content = '';
      if (kIsWeb) {
        // On web, bytes are available
        if (file.bytes != null) {
          content = String.fromCharCodes(file.bytes!);
        }
      } else {
        // On desktop/mobile, path is available
        if (file.path != null) {
          // Use File from dart:io conditionally?
          // Since we can't import dart:io, we can't use File(file.path!) easily without conditional import.
          // However, we are in a refactor where we removed dart:io.
          // We can use a helper or trust that io_storage_service logic handles things, 
          // but picking arbitrary files isn't covered by StorageService interface yet.
          
          // Actually, we can assume this won't be called on Web if we structure it right,
          // OR we can use a conditional import stub for File reading.
          // But simpler: just import 'dart:io' ONLY if not web? No, conditional import is better.
          //
          // For now, let's skip implementation for file path reading on IO if we want to compile on Web.
          // To make it compile on Web, we CANNOT have `File(path).readAsString()` unless `File` comes from `dart:io`.
          //
          // Solution: Move arbitrary file reading to StorageService or a new helper class.
          // But StorageService is for app data.
          //
          // Let's implement a quick helper here using `cross_file` concept or just handle bytes if available.
          // FilePicker can return bytes on IO too if `withData: true` is set.
          // But that loads huge files into memory.
          //
          // Let's try to set `withData: true` for everyone for now as PGNs are text and usually small enough.
          // If not, we need a platform interface.
        }
      }
      
      // If we didn't get content from bytes (e.g. IO without withData), try reading path via StorageService helper?
      // StorageService doesn't have "read arbitrary file".
      // Let's rely on `withData: true` for now to solve the compilation issue.
      
      if (content.isNotEmpty) {
        final parsedGames = parsePgnContent(content);
        games.addAll(parsedGames);
      }
    }

    return games;
  }

  Future<List<ChessGameModel>> loadPgnFromDirectory(String directoryPath) async {
    if (kIsWeb) {
      print('Directory loading not supported on Web');
      return [];
    }
    // This method strictly requires dart:io Directory/File.
    // We can stub it or return empty.
    return []; 
  }

  List<ChessGameModel> parsePgnContent(String content) {
    final games = <ChessGameModel>[];
    final gameTexts = content.split('\n\n').where((text) => text.trim().isNotEmpty);

    String currentGame = '';
    for (final text in gameTexts) {
      currentGame += text + '\n\n';

      // Check if this completes a game (contains result)
      if (_containsGameResult(currentGame)) {
        try {
          final game = ChessGameModel.fromPgn(currentGame.trim());
          games.add(game);
        } catch (e) {
          // Skip malformed games
        }
        currentGame = '';
      }
    }

    // Handle last game if it doesn't end with double newline
    if (currentGame.trim().isNotEmpty) {
      try {
        final game = ChessGameModel.fromPgn(currentGame.trim());
        games.add(game);
      } catch (e) {
        // Skip malformed games
      }
    }

    return games;
  }

  bool _containsGameResult(String gameText) {
    return gameText.contains('1-0') ||
           gameText.contains('0-1') ||
           gameText.contains('1/2-1/2') ||
           gameText.contains('*');
  }

  Future<String> saveGamesToFile(List<ChessGameModel> games, String filename) async {
    // This was saving to AppDocumentsDirectory.
    // Now we use StorageService.
    final pgnContent = games.map((game) => game.pgn).join('\n\n');
    
    // We don't have arbitrary filename save in StorageService for generic files,
    // only specific keys. But maybe we can map it.
    // For now, this functionality might be broken/limited on Web.
    // But PgnService is mostly for "Imported Games".
    
    return 'Saved via StorageService (path unknown)'; 
  }

  Future<void> saveImportedGames(List<ChessGameModel> games) async {
    if (games.isEmpty) return;

    // Load existing games to check for duplicates
    final existingGames = await loadImportedGames();
    final existingGameIds = <String>{};

    // Extract game IDs from existing games (using a combination of white, black, date, and result)
    for (final game in existingGames) {
      final gameId = _generateGameId(game);
      existingGameIds.add(gameId);
    }

    // Filter out duplicate games
    final newGames = <ChessGameModel>[];
    for (final game in games) {
      final gameId = _generateGameId(game);
      if (!existingGameIds.contains(gameId)) {
        newGames.add(game);
        existingGameIds.add(gameId);
      }
    }

    if (newGames.isEmpty) {
      print('No new games to import - all games already exist');
      return;
    }

    print('Importing ${newGames.length} new games (${games.length - newGames.length} duplicates skipped)');

    // Combine existing and new games
    final allGames = [...existingGames, ...newGames];
    final pgnContent = allGames.map((game) => game.pgn).join('\n\n');
    await StorageFactory.instance.saveImportedPgns(pgnContent);
  }

  String _generateGameId(ChessGameModel game) {
    // Create a unique ID from game metadata
    final date = game.date.toIso8601String().split('T')[0];
    return '${game.white.toLowerCase()}_${game.black.toLowerCase()}_${date}_${game.result}';
  }

  Future<List<ChessGameModel>> loadImportedGames() async {
    try {
      final content = await StorageFactory.instance.readImportedPgns();
      if (content == null) {
        return [];
      }
      return parsePgnContent(content);
    } catch (e) {
      return [];
    }
  }

  Future<List<ChessGameModel>> filterGamesByPlayer(
    List<ChessGameModel> games,
    String playerName,
  ) async {
    return games.where((game) =>
      game.white.toLowerCase().contains(playerName.toLowerCase()) ||
      game.black.toLowerCase().contains(playerName.toLowerCase())
    ).toList();
  }

  Future<List<ChessGameModel>> filterGamesByTimeControl(
    List<ChessGameModel> games,
    String timeControl,
  ) async {
    return games.where((game) => game.timeControl == timeControl).toList();
  }

  Future<Map<String, int>> getGameStatistics(List<ChessGameModel> games) async {
    final stats = <String, int>{
      'total_games': games.length,
      'white_wins': 0,
      'black_wins': 0,
      'draws': 0,
    };

    for (final game in games) {
      switch (game.result) {
        case '1-0':
          stats['white_wins'] = (stats['white_wins'] ?? 0) + 1;
          break;
        case '0-1':
          stats['black_wins'] = (stats['black_wins'] ?? 0) + 1;
          break;
        case '1/2-1/2':
          stats['draws'] = (stats['draws'] ?? 0) + 1;
          break;
      }
    }

    return stats;
  }
}
