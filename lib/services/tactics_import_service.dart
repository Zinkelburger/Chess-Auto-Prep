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
import 'tactics_database.dart';

/// Callback for when a new tactics position is found during import
typedef OnPositionFoundCallback = void Function(TacticsPosition position);

/// Callback for progress updates during import
typedef ProgressCallback = void Function(String message);

class TacticsImportService {
  final StockfishService _stockfish = StockfishService();
  final TacticsDatabase _database = TacticsDatabase();
  
  /// Whether to skip games that have already been analyzed
  bool skipAnalyzedGames = true;

  // Win% formula provided by user
  // Win% = 50 + 50 * (2 / (1 + exp(-0.00368208 * centipawns)) - 1)
  double _calculateWinChance(int centipawns) {
    return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * centipawns)) - 1);
  }

  /// Initialize the database (load analyzed game IDs)
  Future<void> initialize() async {
    await _database.loadPositions();
  }

  Future<List<TacticsPosition>> importGamesFromLichess(
    String username, {
    int? maxGames, 
    int depth = 15, 
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    // Ensure database is loaded to check for already-analyzed games
    if (_database.analyzedGameIds.isEmpty) {
      await _database.loadPositions();
    }
    
    final url = Uri.parse('https://lichess.org/api/games/user/$username?max=${maxGames ?? 20}&evals=false&clocks=false&opening=false&moves=true');
    
    try {
      progressCallback?.call('Downloading games from Lichess...');
      final response = await http.get(url, headers: {'Accept': 'application/x-chess-pgn'});
      
      if (response.statusCode == 200) {
        // Save the raw PGNs first
        await _savePgns(response.body);
        return _processGames(response.body, username, depth, progressCallback, onPositionFound);
      } else {
        throw Exception('Failed to fetch games from Lichess: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching games from Lichess: $e');
    }
  }

  Future<List<TacticsPosition>> importGamesFromChessCom(
    String username, {
    int? maxGames, 
    int depth = 15, 
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    // Ensure database is loaded to check for already-analyzed games
    if (_database.analyzedGameIds.isEmpty) {
      await _database.loadPositions();
    }
    
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
    
    return _processGames(gamesToProcess, username, depth, progressCallback, onPositionFound);
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
      if (kDebugMode) print('  GameId from header: ${gameIdMatch.group(1)}');
      return gameIdMatch.group(1)!;
    }
    
    // Try Link header (Chess.com uses this)
    // Format: [Link "https://www.chess.com/game/live/123456789"]
    final linkMatch = RegExp(r'\[Link "([^"]+)"\]').firstMatch(gameText);
    if (linkMatch != null) {
      final link = linkMatch.group(1)!;
      if (kDebugMode) print('  Found Link header: $link');
      // Extract last numeric segment from URL
      final match = RegExp(r'/(\d+)(?:\?|$|#)').firstMatch(link);
      if (match != null) {
        final gameId = 'chesscom_${match.group(1)}';
        if (kDebugMode) print('  Extracted game ID from Link: $gameId');
        return gameId;
      }
      // Fallback: last path segment
      final parts = link.split('/');
      final lastPart = parts.where((p) => p.isNotEmpty).lastOrNull;
      if (lastPart != null && lastPart.toLowerCase() != 'chess.com') {
        final gameId = 'chesscom_$lastPart';
        if (kDebugMode) print('  Extracted game ID from Link (fallback): $gameId');
        return gameId;
      }
    } else {
      if (kDebugMode) print('  No Link header found');
    }
    
    // Try Site URL (Lichess uses full URL in Site header)
    final siteMatch = RegExp(r'\[Site "([^"]+)"\]').firstMatch(gameText);
    if (siteMatch != null) {
      final site = siteMatch.group(1)!;
      final siteLower = site.toLowerCase();
      if (kDebugMode) print('  Found Site header: $site');
      
      // Skip if it's just "Chess.com" without a game ID (case insensitive)
      if (siteLower == 'chess.com' || 
          siteLower == 'https://chess.com' || 
          siteLower == 'https://www.chess.com' ||
          siteLower == 'http://chess.com' ||
          siteLower == 'http://www.chess.com') {
        // Don't use this, fall through to other methods
      } else if (siteLower.contains('lichess.org/')) {
        // Lichess format: https://lichess.org/AbCdEfGh
        final parts = site.split('/');
        final gameId = parts.where((p) => p.isNotEmpty && !p.contains('.')).lastOrNull;
        if (gameId != null && gameId.length >= 6) {
          return 'lichess_$gameId';
        }
      } else if (site.contains('/') && !siteLower.contains('chess.com')) {
        // Other URL format - extract last segment (but not if it's chess.com)
        final parts = site.split('/');
        final lastPart = parts.where((p) => p.isNotEmpty).lastOrNull;
        if (lastPart != null && lastPart.length >= 4 && lastPart.toLowerCase() != 'chess.com') {
          return lastPart;
        }
      }
    }
    
    // Try to create unique ID from game metadata
    final whiteMatch = RegExp(r'\[White "([^"]+)"\]').firstMatch(gameText);
    final blackMatch = RegExp(r'\[Black "([^"]+)"\]').firstMatch(gameText);
    final dateMatch = RegExp(r'\[Date "([^"]+)"\]').firstMatch(gameText);
    final utcTimeMatch = RegExp(r'\[UTCTime "([^"]+)"\]').firstMatch(gameText);
    
    if (whiteMatch != null && blackMatch != null && dateMatch != null) {
      final white = whiteMatch.group(1)!;
      final black = blackMatch.group(1)!;
      final date = dateMatch.group(1)!;
      final time = utcTimeMatch?.group(1) ?? '';
      // Create a deterministic ID from the game details
      final combined = '$white-$black-$date-$time';
      final gameId = 'game_${combined.hashCode.abs()}';
      if (kDebugMode) print('  Created game ID from metadata: $gameId ($white vs $black)');
      return gameId;
    }
    
    // Last resort: generate from hash of content
    final hashId = 'hash_${gameText.hashCode.abs()}';
    if (kDebugMode) print('  Using hash fallback: $hashId');
    return hashId;
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

  Future<List<TacticsPosition>> _processGames(
    String pgnContent, 
    String username, 
    int depth, 
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  ) async {
    final games = _splitPgnIntoGames(pgnContent);
    final positions = <TacticsPosition>[];
    final usernameLower = username.toLowerCase();

    int gameIdx = 0;
    int skippedCount = 0;
    
    for (final gameText in games) {
      gameIdx++;
      
      try {
        // Use dartchess for robust PGN header parsing
        final game = PgnGame.parsePgn(gameText);
        
        // Extract game ID early to check if already analyzed
        // Always use _extractGameId which handles all formats correctly
        final gameId = _extractGameId(gameText);
        
        // Skip if already analyzed
        if (skipAnalyzedGames && _database.isGameAnalyzed(gameId)) {
          skippedCount++;
          if (kDebugMode) {
            print('Skipping already-analyzed game: $gameId');
          }
          progressCallback?.call('Skipping game $gameIdx/${games.length} (already analyzed)...');
          continue;
        }
        
        final progressMsg = 'Analyzing game $gameIdx/${games.length} (depth $depth)... ${skippedCount > 0 ? "($skippedCount skipped)" : ""}';
        progressCallback?.call(progressMsg);
        
        if (kDebugMode) {
          print(progressMsg);
        }
        
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
            // Mark as analyzed even if user not found (to avoid re-checking)
            await _database.markGameAnalyzed(gameId);
            continue;
          }
        }

        // Analyze the game with streaming callback
        final gamePositions = <TacticsPosition>[];
        await _analyzeGame(game, userColor!, depth, gamePositions, onPositionFound, gameId);
        positions.addAll(gamePositions);
        
        // Mark game as analyzed (even if no blunders found)
        await _database.markGameAnalyzed(gameId);
        
      } catch (e) {
        if (kDebugMode) {
          print('Error parsing game $gameIdx: $e');
        }
        continue;
      }
    }

    if (skippedCount > 0) {
      progressCallback?.call('Done! Analyzed ${gameIdx - skippedCount} new games, skipped $skippedCount already-analyzed games.');
    }

    return positions;
  }

  Future<void> _analyzeGame(
    PgnGame game, 
    chess.Color userColor, 
    int depth, 
    List<TacticsPosition> positions,
    OnPositionFoundCallback? onPositionFound,
    String gameId,
  ) async {
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
        int cpA = evalA.effectiveCp;
        int cpB = evalB.effectiveCp;
        
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
              gameId: gameId, // Use the same ID we used for skip-detection
            );
            
            positions.add(tacticsPosition);
            
            // Stream the position immediately if callback provided
            if (onPositionFound != null) {
              onPositionFound(tacticsPosition);
            }
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
