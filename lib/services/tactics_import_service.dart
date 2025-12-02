import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:dartchess_webok/dartchess_webok.dart';
import 'package:chess/chess.dart' as chess;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/tactics_position.dart';
import 'package:chess_auto_prep/models/engine_evaluation.dart';
import 'stockfish_service.dart';

class TacticsImportService {
  final StockfishService _stockfish = StockfishService();

  // Win% formula provided by user
  // Win% = 50 + 50 * (2 / (1 + exp(-0.00368208 * centipawns)) - 1)
  double _calculateWinChance(int centipawns) {
    return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * centipawns)) - 1);
  }

  Future<List<TacticsPosition>> importGamesFromLichess(String username, {int? maxGames, int depth = 15, Function(String)? progressCallback}) async {
    final url = Uri.parse('https://lichess.org/api/games/user/$username?max=${maxGames ?? 20}&evals=false&clocks=false&opening=false&moves=true');
    
    try {
      progressCallback?.call('Downloading games from Lichess...');
      final response = await http.get(url, headers: {'Accept': 'application/x-chess-pgn'});
      
      if (response.statusCode == 200) {
        // Save the raw PGNs first
        await _savePgns(response.body);
        return _processGames(response.body, username, depth, progressCallback);
      } else {
        throw Exception('Failed to fetch games from Lichess: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching games from Lichess: $e');
    }
  }

  Future<List<TacticsPosition>> importGamesFromChessCom(String username, {int? maxGames, int depth = 15, Function(String)? progressCallback}) async {
    int gamesFound = 0;
    int targetGames = maxGames ?? 10;
    List<String> allGames = [];
    
    final now = DateTime.now();
    int currentYear = now.year;
    int currentMonth = now.month;
    
    // Look back up to 3 months
    for (int i = 0; i < 3; i++) {
      if (gamesFound >= targetGames) break;
      
      final formattedMonth = currentMonth.toString().padLeft(2, '0');
      final url = Uri.parse('https://api.chess.com/pub/player/$username/games/$currentYear/$formattedMonth/pgn');
      
      progressCallback?.call('Downloading Chess.com games for $formattedMonth/$currentYear...');
      
      try {
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final games = _splitPgnIntoGames(response.body);
          // Chess.com API returns games in reverse chronological order (newest first)
          // so we add them directly without reversing
          allGames.addAll(games);
          gamesFound += games.length;
        }
      } catch (e) {
        if (kDebugMode) print('Error fetching Chess.com games: $e');
      }
      
      // Go to previous month
      currentMonth--;
      if (currentMonth == 0) {
        currentMonth = 12;
        currentYear--;
      }
    }
    
    if (allGames.isEmpty) {
      throw Exception('No games found in the last 3 months');
    }
    
    // Limit to target games
    final gamesToProcess = allGames.take(targetGames).join('\n\n');
    
    // Save the raw PGNs first
    await _savePgns(gamesToProcess);
    
    return _processGames(gamesToProcess, username, depth, progressCallback);
  }

  /// Save raw PGNs to imported_games.pgn file with GameId headers injected
  Future<void> _savePgns(String pgnContent) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/imported_games.pgn');
      
      // Split into games and inject GameId headers
      final games = _splitPgnIntoGames(pgnContent);
      final processedGames = <String>[];
      
      for (final game in games) {
        final processedGame = _injectGameIdHeader(game);
        processedGames.add(processedGame);
      }
      
      final processedContent = processedGames.join('\n\n');
      
      // Overwrite file (avoid duplicates from repeated imports)
      await file.writeAsString(processedContent);
      
      if (kDebugMode) {
        print('Saved ${games.length} PGNs to ${file.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error saving PGNs: $e');
      }
    }
  }
  
  /// Extract gameId from PGN headers using same logic as TacticsPosition
  String _extractGameId(String gameText) {
    // Try to find existing GameId header
    final gameIdMatch = RegExp(r'\[GameId "([^"]+)"\]').firstMatch(gameText);
    if (gameIdMatch != null) {
      return gameIdMatch.group(1)!;
    }
    
    // Fall back to extracting from Site URL (Chess.com and Lichess)
    final siteMatch = RegExp(r'\[Site "([^"]+)"\]').firstMatch(gameText);
    if (siteMatch != null) {
      final site = siteMatch.group(1)!;
      // Extract last path segment as ID
      final parts = site.split('/');
      if (parts.isNotEmpty) {
        return parts.last;
      }
    }
    
    // Last resort: generate from hash of content
    return gameText.hashCode.abs().toString();
  }
  
  /// Inject GameId header into PGN if not present
  String _injectGameIdHeader(String gameText) {
    // Check if GameId already exists
    if (gameText.contains('[GameId ')) {
      return gameText;
    }
    
    final gameId = _extractGameId(gameText);
    
    // Find where to insert (after last header, before moves)
    final lines = gameText.split('\n');
    final result = <String>[];
    bool addedGameId = false;
    
    for (final line in lines) {
      result.add(line);
      // Insert GameId after the last header line (lines starting with '[')
      if (!addedGameId && line.startsWith('[') && line.endsWith(']')) {
        // Check if next non-empty line is not a header
        final nextIndex = lines.indexOf(line) + 1;
        if (nextIndex < lines.length) {
          final nextLine = lines[nextIndex].trim();
          if (!nextLine.startsWith('[') && nextLine.isNotEmpty) {
            result.add('[GameId "$gameId"]');
            addedGameId = true;
          }
        }
      }
    }
    
    // If we didn't add it yet (edge case), add before moves
    if (!addedGameId) {
      // Find first non-header line
      for (int i = 0; i < result.length; i++) {
        if (!result[i].trim().startsWith('[') && result[i].trim().isNotEmpty) {
          result.insert(i, '[GameId "$gameId"]');
          break;
        }
      }
    }
    
    return result.join('\n');
  }

  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.trim().isNotEmpty) {
          games.add(currentGame);
        }
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      }
    }

    if (inGame && currentGame.trim().isNotEmpty) {
      games.add(currentGame);
    }

    return games;
  }

  Future<List<TacticsPosition>> _processGames(String pgnContent, String username, int depth, Function(String)? progressCallback) async {
    final games = _splitPgnIntoGames(pgnContent);
    final positions = <TacticsPosition>[];
    final usernameLower = username.toLowerCase();

    int gameIdx = 0;
    for (final gameText in games) {
      gameIdx++;
      final progressMsg = 'Analyzing game $gameIdx/${games.length} (depth $depth)...';
      progressCallback?.call(progressMsg);
      
      if (kDebugMode) {
        print(progressMsg);
      }

      try {
        // Use dartchess for robust PGN header parsing
        final game = PgnGame.parsePgn(gameText);
        
        final white = game.headers['White']?.toLowerCase() ?? '';
        final black = game.headers['Black']?.toLowerCase() ?? '';
        
        chess.Color? userColor; // chess.dart Color enum
        
        if (white == usernameLower) {
          userColor = chess.Color.WHITE;
        } else if (black == usernameLower) {
          userColor = chess.Color.BLACK;
        } else {
          if (white.contains(usernameLower)) {
            userColor = chess.Color.WHITE;
          } else if (black.contains(usernameLower)) {
            userColor = chess.Color.BLACK;
          } else {
            continue;
          }
        }

        await _analyzeGame(game, userColor!, depth, positions);
        
      } catch (e) {
        if (kDebugMode) {
          print('Error parsing game $gameIdx: $e');
        }
        continue;
      }
    }

    return positions;
  }

  Future<void> _analyzeGame(PgnGame game, chess.Color userColor, int depth, List<TacticsPosition> positions) async {
    // Linearize moves from the game (SAN strings)
    final moves = <String>[];
    var node = game.moves;
    while (node.children.isNotEmpty) {
      final child = node.children.first;
      moves.add(child.data.san);
      node = child;
    }

    // Use chess.dart for game state management
    final chessGame = chess.Chess();
    int moveNumber = 1;
    
    for (final san in moves) {
      final isUserTurn = chessGame.turn == userColor;
      
      if (isUserTurn) {
        // 1. Analyze Position A (Before Move)
        final evalA = await _stockfish.getEvaluation(chessGame.fen, depth: depth);
        
        // 2. Make the move
        final fenBefore = chessGame.fen;
        final moveMap = chessGame.move(san); // Plays the move
        if (moveMap == null) break; // Invalid move?
        
        final fenAfter = chessGame.fen;
        
        // 3. Analyze Position B (After Move)
        final evalB = await _stockfish.getEvaluation(fenAfter, depth: depth);
        
        // 4. Calculate Win Chances
        int cpA = _getEffectiveCp(evalA);
        int cpB = _getEffectiveCp(evalB);
        
        // Normalize to User perspective
        if (userColor == chess.Color.BLACK) {
          cpA = -cpA;
          cpB = -cpB;
        }
        
        final winChanceA = _calculateWinChance(cpA);
        final winChanceB = _calculateWinChance(cpB);
        
        final delta = winChanceA - winChanceB;
        
        // Classify: Blunder (>30%), Mistake (20-30%), or OK
        final isBlunder = delta > 30;
        final isMistake = delta > 20 && delta <= 30;
        
        // Debug output for every move
        if (kDebugMode) {
          final status = isBlunder ? '⚠️ BLUNDER' : (isMistake ? '⚠ MISTAKE' : '✓');
          print('Move $moveNumber. $san | Before: ${cpA}cp (${winChanceA.toStringAsFixed(1)}%) → After: ${cpB}cp (${winChanceB.toStringAsFixed(1)}%) | Δ${delta.toStringAsFixed(1)}% | $status');
        }
        
        if (isBlunder || isMistake) {
          // Found Blunder or Mistake!
          if (kDebugMode) {
            print('  → PV from Stockfish: ${evalA.pv}');
          }
          if (evalA.pv.isNotEmpty) {
            final bestMoveUci = evalA.pv.first;
            
            // Generate correct line as pure SAN moves (for solution matching)
            final correctLine = <String>[];
            final tempGame = chess.Chess.fromFEN(fenBefore);
            
            int pvLimit = math.min(3, evalA.pv.length);
            for (int i = 0; i < pvLimit; i++) {
              final uci = evalA.pv[i];
              final sanMove = _makeUciMoveAndGetSan(tempGame, uci);
              
              if (kDebugMode) {
                print('  → UCI: $uci → SAN: $sanMove');
              }
              
              if (sanMove != null) {
                // Store pure SAN move (e.g., "Nf3", "e4") for solution matching
                correctLine.add(sanMove);
              }
            }
            
            if (kDebugMode) {
              print('  → correctLine: $correctLine');
            }
            
            // Format best move SAN for display
            final bestMoveSan = _formatUciToSan(fenBefore, bestMoveUci);

            final chanceA = winChanceA.toStringAsFixed(1);
            final chanceB = winChanceB.toStringAsFixed(1);
            final mistakeType = isBlunder ? '??' : '?';
            final label = isBlunder ? 'Blunder' : 'Mistake';
            final analysis = '$label. Win chance dropped from $chanceA% to $chanceB% (${delta.toStringAsFixed(1)}%). Best was $bestMoveSan.';

            final tacticsPosition = TacticsPosition(
              fen: fenBefore,
              userMove: san,
              correctLine: correctLine,
              mistakeType: mistakeType,
              mistakeAnalysis: analysis,
              positionContext: 'Move $moveNumber, ${userColor == chess.Color.WHITE ? 'White' : 'Black'} to play',
              gameWhite: game.headers['White'] ?? '',
              gameBlack: game.headers['Black'] ?? '',
              gameResult: game.headers['Result'] ?? '*',
              gameDate: game.headers['Date'] ?? '',
              gameId: game.headers['GameId'] ?? game.headers['Site']?.split('/').last ?? '',
            );
            
            positions.add(tacticsPosition);
          }
        }
      } else {
        // Opponent's move
        chessGame.move(san);
      }
      
      // Update move number
      if (chessGame.turn == chess.Color.WHITE) {
        moveNumber++;
      }
    }
  }

  int _getEffectiveCp(EngineEvaluation eval) {
    if (eval.scoreMate != null) {
      if (eval.scoreMate! > 0) {
        return 10000 - eval.scoreMate!;
      } else {
        return -10000 - eval.scoreMate!;
      }
    }
    return eval.scoreCp ?? 0;
  }
  
  String? _makeUciMoveAndGetSan(chess.Chess game, String uci) {
    final from = uci.substring(0, 2);
    final to = uci.substring(2, 4);
    String? promotion;
    if (uci.length > 4) {
      promotion = uci.substring(4, 5);
    }
    
    // Build move map
    Map<String, String?> moveMap = {'from': from, 'to': to};
    if (promotion != null) {
      moveMap['promotion'] = promotion;
    }
    
    // Get the SAN before making the move by finding the matching legal move
    final legalMoves = game.generate_moves();
    String? sanMove;
    
    // Convert from/to strings to square indices
    final fromSquare = chess.Chess.SQUARES[from];
    final toSquare = chess.Chess.SQUARES[to];
    
    for (final move in legalMoves) {
      // Move class has .from, .to, .promotion properties
      if (move.from == fromSquare && move.to == toSquare) {
        // Check promotion matches if applicable
        if (promotion == null || move.promotion == null ||
            move.promotion.toString().toLowerCase() == promotion.toLowerCase()) {
          // Generate SAN for this move
          sanMove = game.move_to_san(move);
          break;
        }
      }
    }
    
    // Make the move to advance game state
    if (sanMove != null) {
      game.move(moveMap);
    }
    
    return sanMove;
  }

  String _formatUciToSan(String fen, String uci) {
    final game = chess.Chess.fromFEN(fen);
    final san = _makeUciMoveAndGetSan(game, uci);
    return san ?? uci;
  }
}
