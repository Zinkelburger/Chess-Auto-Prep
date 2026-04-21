import 'package:flutter/foundation.dart';

import '../models/chess_game.dart';
import 'storage/storage_factory.dart';

class PgnService {
  List<ChessGameModel> parsePgnContent(String content) {
    final games = <ChessGameModel>[];
    final gameTexts = content.split('\n\n').where((text) => text.trim().isNotEmpty);

    String currentGame = '';
    for (final text in gameTexts) {
      currentGame += '$text\n\n';

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
      if (kDebugMode) {
        debugPrint('No new games to import - all games already exist');
      }
      return;
    }

    if (kDebugMode) {
      debugPrint('Importing ${newGames.length} new games '
          '(${games.length - newGames.length} duplicates skipped)');
    }

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
