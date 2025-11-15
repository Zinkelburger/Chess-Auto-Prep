import 'dart:io';
import 'package:chess/chess.dart' as chess_engine;
import 'package:dartchess_webok/dartchess_webok.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/tactics_position.dart';

class TacticsService {
  /// Analyze PGN files from imported_games directory to extract tactical positions
  Future<List<TacticsPosition>> generateTacticsFromLichess(String username) async {
    return await _extractTacticsFromImportedGames(username);
  }

  /// Same as generateTacticsFromLichess - both analyze imported PGN files
  Future<List<TacticsPosition>> analyzeWeakPositions(String username) async {
    return await _extractTacticsFromImportedGames(username);
  }

  Future<List<TacticsPosition>> _extractTacticsFromImportedGames(String username) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/imported_games.pgn');

    if (!await file.exists()) {
      throw Exception('No imported games found. Please import games first.');
    }

    if (kDebugMode) {
      print('Regenerating tactics from imported_games.pgn');
    }

    final content = await file.readAsString();
    final games = _extractGamesFromPgn(content);
    final allPositions = <TacticsPosition>[];

    if (kDebugMode) {
      print('Processing ${games.length} games for tactics');
    }

    for (int i = 0; i < games.length; i++) {
      final gameData = games[i];
      try {
        final gamePositions = await _extractPositionsFromGameData(gameData, username);
        allPositions.addAll(gamePositions);

        if (kDebugMode && gamePositions.isNotEmpty) {
          print('Game ${i+1}: Found ${gamePositions.length} positions');
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error parsing game ${i+1}: $e');
        }
        continue;
      }
    }

    if (kDebugMode) {
      print('Total tactical positions found: ${allPositions.length}');
    }

    // Save to CSV
    await _saveTacticsToCSV(allPositions);

    return allPositions;
  }

  Future<List<TacticsPosition>> _analyzePgnContent(String content, String username) async {
    final positions = <TacticsPosition>[];

    // Split PGN content into individual games
    final games = _extractGamesFromPgn(content);

    if (kDebugMode) {
      print('Extracted ${games.length} games from PGN');
    }

    for (final gameData in games) {
      try {
        final gamePositions = await _extractPositionsFromGameData(gameData, username);
        positions.addAll(gamePositions);
      } catch (e) {
        if (kDebugMode) {
          print('Error parsing game: $e');
        }
        continue;
      }
    }

    return positions;
  }

  List<GameData> _extractGamesFromPgn(String content) {
    final games = <GameData>[];
    final lines = content.split('\n');

    Map<String, String>? currentHeaders;
    String currentMoves = '';

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        // Header line
        final match = RegExp(r'\[(\w+)\s+"([^"]*)"\]').firstMatch(trimmed);
        if (match != null) {
          currentHeaders ??= {};
          currentHeaders[match.group(1)!] = match.group(2)!;
        }
      } else if (trimmed.isNotEmpty && !trimmed.startsWith('[')) {
        // Moves line
        currentMoves += '$trimmed ';
      } else if (trimmed.isEmpty && currentHeaders != null && currentMoves.isNotEmpty) {
        // End of game
        games.add(GameData(headers: currentHeaders, moves: currentMoves.trim()));
        currentHeaders = null;
        currentMoves = '';
      }
    }

    // Don't forget the last game
    if (currentHeaders != null && currentMoves.isNotEmpty) {
      games.add(GameData(headers: currentHeaders, moves: currentMoves.trim()));
    }

    return games;
  }

  Future<List<TacticsPosition>> _extractPositionsFromGameData(GameData gameData, String username) async {
    final positions = <TacticsPosition>[];

    // Check if user played in this game
    final white = gameData.headers['White']?.toLowerCase() ?? '';
    final black = gameData.headers['Black']?.toLowerCase() ?? '';
    final usernameLower = username.toLowerCase();

    Color? userColor;
    if (white.contains(usernameLower)) {
      userColor = Color.WHITE;
    } else if (black.contains(usernameLower)) {
      userColor = Color.BLACK;
    } else {
      return positions; // User not in this game
    }

    if (kDebugMode) {
      print('Found user $username in game: ${gameData.headers['White']} vs ${gameData.headers['Black']} (user is ${userColor == Color.WHITE ? 'white' : 'black'})');
    }

    // PYTHON APPROACH: Extract mistake comments from text, then replay moves with chess engine
    final chess = Chess();

    // 1. Extract mistake annotations from the raw PGN text (like Python does with comments)
    final mistakeAnnotations = <String, Map<String, String>>{};
    final mistakePattern = RegExp(r'(\d+)\.{3}\s*([a-h1-8NBRQKO-]+[+#!?]*)\s*(\{[^}]*?(Mistake|Blunder)[^}]*?\})');
    final matches = mistakePattern.allMatches(gameData.moves);

    for (final match in matches) {
      final moveNumber = match.group(1) ?? '';
      final moveWithSymbols = match.group(2) ?? '';
      final comment = match.group(3) ?? '';
      final mistakeType = comment.contains('Blunder') ? '??' : '?';

      // Remove mistake symbols to get clean move
      final cleanMove = moveWithSymbols.replaceAll(RegExp(r'[+#!?]+$'), '');

      mistakeAnnotations['$moveNumber...$cleanMove'] = {
        'type': mistakeType,
        'comment': comment,
        'originalMove': moveWithSymbols,
      };
    }

    if (kDebugMode) {
      print('Found ${mistakeAnnotations.length} mistake annotations: ${mistakeAnnotations.keys.toList()}');
    }

    // 2. PYTHON LOGIC: Replay ALL moves from the game text, checking each one
    // Remove variations and comments, extract just the main line moves
    String cleanText = gameData.moves
        .replaceAll(RegExp(r'\s*(1-0|0-1|1/2-1/2|\*)\s*$'), '') // Remove result
        .replaceAll(RegExp(r'\{[^}]*\}'), '') // Remove all comments
        .replaceAll(RegExp(r'\([^)]*\)'), ''); // Remove all variations

    // Extract moves from clean mainline
    final movePattern = RegExp(r'(\d+)\.(\.\.)?\s*([a-h1-8NBRQKO][a-h1-8xO=-]*[+#!?]*(?:=[QRBN])?)');
    final allMoves = movePattern.allMatches(cleanText).map((match) => match.group(3)!).toList();

    if (kDebugMode) {
      print('Extracted ${allMoves.length} moves from mainline: ${allMoves.take(10).join(', ')}...');
    }

    // 3. PYTHON LOGIC: Walk through moves using chess engine (like board.push(move))
    int fullMoveNumber = 1;
    bool isWhiteTurn = true;

    for (int i = 0; i < allMoves.length; i++) {
      final moveString = allMoves[i];
      final cleanMove = moveString.replaceAll(RegExp(r'[+#!?]+$'), '');
      final isUserMove = chess.turn == userColor;

      // Check if this is a user mistake BEFORE making the move (Python: get FEN before mistake)
      if (isUserMove) {
        final moveKey = '$fullMoveNumber...$cleanMove';

        if (mistakeAnnotations.containsKey(moveKey)) {
          // PYTHON LOGIC: Get FEN BEFORE the mistake move
          final fenBeforeMistake = chess.fen;

          final annotation = mistakeAnnotations[moveKey]!;
          final mistakeType = annotation['type']!;
          final comment = annotation['comment']!;
          final mistakeAnalysis = _extractMistakeAnalysisFromText(comment);
          final correctLine = _extractCorrectLineFromAnalysis(mistakeAnalysis);

          final position = TacticsPosition(
            fen: fenBeforeMistake,
            userMove: cleanMove,
            correctLine: correctLine,
            mistakeType: mistakeType,
            mistakeAnalysis: mistakeAnalysis,
            positionContext: 'Move $fullMoveNumber, ${userColor == Color.WHITE ? 'White' : 'Black'} to play',
            gameWhite: gameData.headers['White'] ?? '',
            gameBlack: gameData.headers['Black'] ?? '',
            gameResult: gameData.headers['Result'] ?? '*',
            gameDate: gameData.headers['Date'] ?? '',
            gameId: gameData.headers['GameId'] ?? gameData.headers['Site']?.split('/').last ?? '',
          );

          positions.add(position);

          if (kDebugMode) {
            print('Found tactical position: $mistakeType at move $fullMoveNumber');
            print('FEN: $fenBeforeMistake');
            print('User move: $cleanMove');
          }
        }
      }

      // PYTHON LOGIC: Make the move to continue (like board.push(move))
      try {
        if (!chess.move(cleanMove)) {
          if (kDebugMode) {
            print('Failed to make move: $cleanMove at move $fullMoveNumber - stopping position tracking');
          }
          break;
        }
      } catch (e) {
        if (kDebugMode) {
          print('Exception making move $cleanMove: $e - stopping position tracking');
        }
        break;
      }

      // Update move counters (Python: board.fullmove_number)
      if (!isWhiteTurn) {
        fullMoveNumber++;
      }
      isWhiteTurn = !isWhiteTurn;
    }

    return positions;
  }

  List<MoveData> _extractAllMovesFromText(String movesText) {
    final moves = <MoveData>[];

    // Remove game result and clean up
    String cleanText = movesText.replaceAll(RegExp(r'\s*(1-0|0-1|1/2-1/2|\*)\s*$'), '');

    // Better pattern that captures the full move including captures and special notation
    final movePattern = RegExp(r'(\d+)\.(\.\.)?\s+([a-h1-8NBRQKO][a-h1-8xO=-]*[+#!?]*(?:=[QRBN])?)');
    final matches = movePattern.allMatches(cleanText);

    for (final match in matches) {
      final move = match.group(3)!;

      // Remove annotations and validate
      final cleanMove = move.replaceAll(RegExp(r'[+#!?]+$'), '');
      if (_isValidChessMove(cleanMove)) {
        moves.add(MoveData(san: cleanMove, comment: '', mistakeType: '', hasMistake: false));
      }
    }

    return moves;
  }

  bool _isValidChessMove(String move) {
    if (move.isEmpty || move.length > 10) return false;

    // Valid chess move patterns (much more permissive)
    return RegExp(r'^([a-h][1-8]|[NBRQK][a-h1-8]*x?[a-h][1-8]|O-O(-O)?|[a-h]x[a-h][1-8]|[NBRQK][a-h1-8]+|[a-h][1-8]=?[QRBN]?)$').hasMatch(move) ||
           move == 'O-O' || move == 'O-O-O';
  }

  String _extractMistakeAnalysisFromText(String text) {
    // Extract the analysis between first { }
    final match = RegExp(r'\{\s*([^}]+?)\s*\}').firstMatch(text);
    return match?.group(1)?.trim() ?? '';
  }

  List<String> _extractCorrectLineFromAnalysis(String analysis) {
    // Look for "X was best" pattern
    final bestMoveMatch = RegExp(r'([a-h1-8NBRQKO-]+[+#]?)\s+was\s+best').firstMatch(analysis);
    if (bestMoveMatch != null) {
      return [bestMoveMatch.group(1)!];
    }
    return [];
  }

  List<MoveData> _extractMovesFromText(String movesText) {
    final moveList = <MoveData>[];

    // Remove result indicators
    String cleanText = movesText.replaceAll(RegExp(r'\s*(1-0|0-1|1/2-1/2|\*)\s*$'), '');

    // Split by moves using a more sophisticated approach
    // Match pattern: move followed by optional annotation and comment
    final movePattern = RegExp(r'(\d+\.\s*)?([a-h1-8NBRQKO-]+[+#]?[?!]*)\s*(\{[^}]+\})?');
    final matches = movePattern.allMatches(cleanText);

    for (final match in matches) {
      final move = match.group(2);
      final commentBlock = match.group(3);

      if (move == null || !_isValidMoveToken(move)) continue;

      String comment = '';
      String mistakeType = '';
      bool hasMistake = false;

      if (commentBlock != null) {
        // Extract comment content between {}
        comment = commentBlock.replaceAll(RegExp(r'[{}]'), '').trim();

        // Check for mistakes/blunders in the comment
        if (comment.contains('Blunder')) {
          mistakeType = '??';
          hasMistake = true;
        } else if (comment.contains('Mistake')) {
          mistakeType = '?';
          hasMistake = true;
        } else if (comment.contains('Inaccuracy')) {
          mistakeType = '?!';
          hasMistake = true;
        }
      }

      // Clean the move notation (remove annotations like ?!, ??, etc.)
      final cleanMove = move.replaceAll(RegExp(r'[?!+#]+$'), '');

      moveList.add(MoveData(
        san: cleanMove,
        comment: comment,
        mistakeType: mistakeType,
        hasMistake: hasMistake,
      ));
    }

    return moveList;
  }

  bool _isValidMoveToken(String token) {
    // Remove annotations like +, #, !, ?, etc.
    final cleanToken = token.replaceAll(RegExp(r'[+#!?]+$'), '');

    // Check various move patterns
    return RegExp(r'^[a-h][1-8]$').hasMatch(cleanToken) || // pawn move
           RegExp(r'^[NBRQK][a-h1-8]*x?[a-h][1-8]$').hasMatch(cleanToken) || // piece move
           RegExp(r'^O-O(-O)?$').hasMatch(cleanToken) || // castling
           RegExp(r'^[a-h]x[a-h][1-8]$').hasMatch(cleanToken); // pawn capture
  }

  List<String> _extractCorrectLineFromComment(String comment) {
    final correctMoves = <String>[];

    // Look for "X was best" pattern
    final bestMoveMatch = RegExp(r'([a-h][1-8]|[NBRQK][a-h1-8]*x?[a-h][1-8]|O-O(?:-O)?)\s+was\s+best').firstMatch(comment);
    if (bestMoveMatch != null) {
      correctMoves.add(bestMoveMatch.group(1)!);
    }

    // For now, we just extract the single best move
    // In the future, we could parse more complex variations from Lichess comments
    return correctMoves;
  }

  String _convertSanToUci(String san, Chess chess) {
    try {
      // Try to parse the SAN move and convert to UCI
      final moves = chess.moves({'verbose': true});
      for (final move in moves) {
        if (move is Map<String, dynamic> && move['san'] == san) {
          return '${move['from']}${move['to']}';
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error converting SAN to UCI: $e');
      }
    }

    // Fallback: return the SAN move
    return san;
  }

  Future<List<TacticsPosition>> _loadTacticsFromCSV(File csvFile) async {
    final positions = <TacticsPosition>[];

    try {
      final content = await csvFile.readAsString();
      final lines = content.split('\n');

      // Skip header line
      for (int i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;

        // Parse CSV line - handle quoted values
        final values = _parseCSVLine(line);
        if (values.length >= 15) {
          try {
            final position = TacticsPosition.fromCsv(values);
            positions.add(position);
          } catch (e) {
            if (kDebugMode) {
              print('Error parsing CSV line: $e');
            }
          }
        }
      }

      if (kDebugMode) {
        print('Loaded ${positions.length} positions from CSV');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading CSV: $e');
      }
      rethrow;
    }

    return positions;
  }

  List<String> _parseCSVLine(String line) {
    final values = <String>[];
    var current = '';
    var inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        values.add(current);
        current = '';
      } else {
        current += char;
      }
    }

    // Don't forget the last value
    values.add(current);

    return values;
  }

  Future<void> _saveTacticsToCSV(List<TacticsPosition> positions) async {
    try {
      // Save to app documents directory (Flutter idiomatic way)
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/tactics_positions.csv');

      final csvContent = StringBuffer();
      csvContent.writeln('fen,user_move,correct_line,mistake_type,mistake_analysis,position_context,game_white,game_black,game_result,game_date,game_id,difficulty,last_reviewed,review_count,success_rate,created_date');

      for (final position in positions) {
        csvContent.writeln(
          '"${position.fen}","${position.userMove}","${position.correctLine.join('|')}",'
          '"${position.mistakeType}","${position.mistakeAnalysis}","${position.positionContext}",'
          '"${position.gameWhite}","${position.gameBlack}","${position.gameResult}",'
          '"${position.gameDate}","${position.gameId}","${position.difficulty}",'
          '"${position.lastReviewed?.toIso8601String() ?? ''}","${position.reviewCount}","${position.successRate}",'
          '"${DateTime.now().toIso8601String()}"'
        );
      }

      await file.writeAsString(csvContent.toString());
      if (kDebugMode) {
        print('Tactics positions saved to: ${file.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error saving tactics to CSV: $e');
      }
    }
  }
}

class GameData {
  final Map<String, String> headers;
  final String moves;

  GameData({required this.headers, required this.moves});
}

class MoveData {
  final String san;
  final String comment;
  final String mistakeType;
  final bool hasMistake;

  MoveData({
    required this.san,
    required this.comment,
    required this.mistakeType,
    required this.hasMistake,
  });
}