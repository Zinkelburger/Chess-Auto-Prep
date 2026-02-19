import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:dartchess_webok/dartchess_webok.dart';
import 'package:chess/chess.dart' as chess;
import 'package:flutter/foundation.dart';
import '../models/tactics_position.dart';
import '../models/engine_settings.dart';
import 'package:chess_auto_prep/models/engine_evaluation.dart';
import 'engine/stockfish_service.dart';
import 'tactics_database.dart';
import 'lichess_auth_service.dart';
import 'storage/storage_factory.dart';
import 'tactics_parallel_analyzer_stub.dart'
    if (dart.library.io) 'tactics_parallel_analyzer.dart' as parallel;

/// Callback for when a new tactics position is found during import
typedef OnPositionFoundCallback = void Function(TacticsPosition position);

/// Callback for progress updates during import
typedef ProgressCallback = void Function(String message);

class TacticsImportService {
  final StockfishService _stockfish = StockfishService();
  final TacticsDatabase _database = TacticsDatabase();
  
  /// Whether to skip games that have already been analyzed
  bool skipAnalyzedGames = true;
  
  /// Check if engine-based analysis is available on this platform
  bool get isAnalysisAvailable => _stockfish.isAvailable.value;

  /// Whether parallel multi-core analysis is available (desktop only).
  static bool get isParallelAvailable => parallel.isParallelAnalysisAvailable;

  /// Number of logical CPU cores on this machine (1 on web).
  static int get availableCores => parallel.availableProcessors;

  // Lichess winning chances formula (from scalachess)
  // Returns [-1, +1] where -1 = losing, 0 = equal, +1 = winning
  // https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/eval.scala
  static const double _multiplier = -0.00368208;
  
  double _winningChances(int centipawns) {
    final capped = centipawns.clamp(-1000, 1000);
    return 2 / (1 + math.exp(_multiplier * capped)) - 1;
  }
  
  // Win percent for display purposes [0, 100]
  double _winPercent(int centipawns) {
    return 50 + 50 * _winningChances(centipawns);
  }

  /// Initialize the database (load analyzed game IDs)
  Future<void> initialize() async {
    await _database.loadPositions();
  }

  Future<List<TacticsPosition>> importGamesFromLichess(
    String username, {
    int? maxGames, 
    int depth = 15,
    int? maxCores,
    int? maxLoadPercent,
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    // Ensure database is loaded to check for already-analyzed games
    if (_database.analyzedGameIds.isEmpty) {
      await _database.loadPositions();
    }
    
    // On web, we might run into CORS issues with direct Lichess API calls.
    // If that happens, we'd need a proxy, but for now we try direct.
    final url = Uri.parse('https://lichess.org/api/games/user/$username?max=${maxGames ?? 20}&evals=false&clocks=false&opening=false&moves=true');
    
    try {
      progressCallback?.call('Downloading games from Lichess...');
      final headers = await LichessAuthService().getHeaders(
        {'Accept': 'application/x-chess-pgn'},
      );
      final response = await http.get(url, headers: headers);
      
      if (response.statusCode == 200) {
        // Save the raw PGNs first
        await _savePgns(response.body);
        return _processGames(response.body, username, depth, progressCallback, onPositionFound, maxCores: maxCores, maxLoadPercent: maxLoadPercent);
      } else {
        throw Exception('Failed to fetch games from Lichess: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching games from Lichess: $e');
    }
  }

  /// Fetch the list of monthly archive URLs from Chess.com.
  ///
  /// Returns the URLs in chronological order (oldest first), or an empty
  /// list if the player has no archives.
  Future<List<String>> _fetchChesscomArchives(String username) async {
    final url = Uri.parse(
      'https://api.chess.com/pub/player/${username.toLowerCase()}'
      '/games/archives',
    );
    final response = await http.get(url);
    if (response.statusCode != 200) return [];
    final data = json.decode(response.body) as Map<String, dynamic>;
    return List<String>.from(data['archives'] as List);
  }

  Future<List<TacticsPosition>> importGamesFromChessCom(
    String username, {
    int? maxGames, 
    int depth = 15,
    int? maxCores,
    int? maxLoadPercent,
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    // Ensure database is loaded to check for already-analyzed games
    if (_database.analyzedGameIds.isEmpty) {
      await _database.loadPositions();
    }
    
    int targetGames = maxGames ?? 10;
    List<String> allGames = [];
    
    progressCallback?.call('Fetching Chess.com game archives for $username…');
    
    // Use the archives endpoint to discover which months actually have
    // games, rather than blindly checking the last N months (which fails
    // for inactive players).
    final archives = await _fetchChesscomArchives(username);
    
    if (archives.isEmpty) {
      throw Exception('No game archives found for $username on Chess.com');
    }
    
    // Walk backwards from the most recent archive.
    for (int i = archives.length - 1;
        i >= 0 && allGames.length < targetGames;
        i--) {
      progressCallback?.call(
        'Downloading Chess.com games (${allGames.length}/$targetGames)…',
      );
      
      try {
        final response = await http.get(Uri.parse('${archives[i]}/pgn'));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          final games = _splitPgnIntoGames(response.body);
          allGames.addAll(games);
        }
      } catch (e) {
        if (kDebugMode) print('Error fetching Chess.com games: $e');
      }
    }
    
    if (allGames.isEmpty) {
      throw Exception('No games found for $username on Chess.com');
    }
    
    // Limit to target games
    final gamesToProcess = allGames.take(targetGames).join('\n\n');
    
    // Save the raw PGNs first
    await _savePgns(gamesToProcess);
    
    return _processGames(gamesToProcess, username, depth, progressCallback, onPositionFound, maxCores: maxCores, maxLoadPercent: maxLoadPercent);
  }

  /// Save raw PGNs to storage with GameId headers injected.
  ///
  /// Appends to existing PGNs, skipping any games whose GameId already
  /// appears in the stored file.
  Future<void> _savePgns(String pgnContent) async {
    try {
      final games = _splitPgnIntoGames(pgnContent);
      final processedGames = games.map(_injectGameIdHeader).toList();
      
      final existing = await StorageFactory.instance.readImportedPgns() ?? '';
      
      // Collect GameIds already in storage to avoid duplicates
      final existingIds = <String>{};
      if (existing.isNotEmpty) {
        for (final match in RegExp(r'\[GameId "([^"]+)"\]').allMatches(existing)) {
          existingIds.add(match.group(1)!);
        }
      }
      
      // Only append games not already stored
      final newGames = processedGames.where((game) {
        final idMatch = RegExp(r'\[GameId "([^"]+)"\]').firstMatch(game);
        return idMatch == null || !existingIds.contains(idMatch.group(1));
      }).toList();
      
      if (newGames.isEmpty) {
        if (kDebugMode) print('All ${games.length} PGNs already in storage, nothing to append');
        return;
      }
      
      final newContent = existing.isEmpty
          ? newGames.join('\n\n')
          : '$existing\n\n${newGames.join('\n\n')}';
      await StorageFactory.instance.saveImportedPgns(newContent);
      
      if (kDebugMode) {
        print('Appended ${newGames.length} new PGNs to storage (${games.length - newGames.length} duplicates skipped)');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error saving PGNs: $e');
      }
    }
  }
  
  /// Extract game ID from PGN headers.
  ///
  /// Lichess provides the game URL in the [Site] header, Chess.com in [Link].
  /// Both APIs always include one of these, so we only handle those two
  /// sources (plus our own injected [GameId] header). Returns empty string
  /// if no ID can be determined, which causes the game to be analyzed every
  /// time (safe fallback).
  String _extractGameId(String gameText) {
    // 1. Our own injected GameId header (from a previous import)
    final gameIdMatch = RegExp(r'\[GameId "([^"]+)"\]').firstMatch(gameText);
    if (gameIdMatch != null) {
      return gameIdMatch.group(1)!;
    }
    
    // 2. Chess.com: [Link "https://www.chess.com/game/live/123456789"]
    final linkMatch = RegExp(r'\[Link "([^"]+)"\]').firstMatch(gameText);
    if (linkMatch != null) {
      final link = linkMatch.group(1)!;
      final match = RegExp(r'/(\d+)(?:\?|$|#)').firstMatch(link);
      if (match != null) {
        return 'chesscom_${match.group(1)}';
      }
      // Fallback: last path segment
      final parts = link.split('/');
      final lastPart = parts.where((p) => p.isNotEmpty).lastOrNull;
      if (lastPart != null && lastPart.toLowerCase() != 'chess.com') {
        return 'chesscom_$lastPart';
      }
    }
    
    // 3. Lichess: [Site "https://lichess.org/AbCdEfGh"]
    final siteMatch = RegExp(r'\[Site "([^"]+)"\]').firstMatch(gameText);
    if (siteMatch != null) {
      final site = siteMatch.group(1)!;
      if (site.toLowerCase().contains('lichess.org/')) {
        final parts = site.split('/');
        final gameId = parts.where((p) => p.isNotEmpty && !p.contains('.')).lastOrNull;
        if (gameId != null && gameId.length >= 6) {
          return 'lichess_$gameId';
        }
      }
    }
    
    // No recognizable game ID found
    if (kDebugMode) {
      print('Warning: could not extract game ID from PGN headers');
    }
    return '';
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
    OnPositionFoundCallback? onPositionFound, {
    int? maxCores,
    int? maxLoadPercent,
  }) async {
    final games = _splitPgnIntoGames(pgnContent);
    final usernameLower = username.toLowerCase();

    // ── Pre-filter: skip already-analyzed games ──────────────
    final gameTasks = <Map<String, dynamic>>[];
    int skippedCount = 0;

    for (int i = 0; i < games.length; i++) {
      final gameId = _extractGameId(games[i]);
      if (skipAnalyzedGames && _database.isGameAnalyzed(gameId)) {
        skippedCount++;
        if (kDebugMode) print('Skipping already-analyzed game: $gameId');
        progressCallback?.call(
          'Skipping game ${i + 1}/${games.length} (already analyzed)...',
        );
        continue;
      }
      gameTasks.add({
        'gameText': games[i],
        'globalIndex': i + 1,
        'gameId': gameId,
      });
    }

    if (gameTasks.isEmpty) {
      progressCallback?.call(
        'All ${games.length} games already analyzed!',
      );
      return [];
    }

    // ── PARALLEL PATH (desktop — works fine with 1 game / 1 core) ──
    if (parallel.isParallelAnalysisAvailable) {
      try {
        final settings = EngineSettings();
        final loadPct = maxLoadPercent ?? settings.maxSystemLoad;
        final hashBudget =
            (EngineSettings.systemRamMb * loadPct ~/ 100)
                .clamp(64, EngineSettings.systemRamMb);
        final hashPerWorker =
            hashBudget ~/ (math.max(1, maxCores ?? settings.cores) + 1);

        final positions = await parallel.analyzeGamesParallel(
          gameTasks: gameTasks,
          username: usernameLower,
          depth: depth,
          totalGames: games.length,
          maxCores: maxCores,
          hashPerWorkerMb: hashPerWorker.clamp(16, hashBudget),
          progressCallback: progressCallback,
          onPositionFound: onPositionFound,
          onGameComplete: (gameId) => _database.markGameAnalyzed(gameId),
        );
        progressCallback?.call(
          'Done! Analyzed ${gameTasks.length} games'
          '${skippedCount > 0 ? ', skipped $skippedCount' : ''}. '
          'Found ${positions.length} tactics positions.',
        );
        return positions;
      } catch (e) {
        if (kDebugMode) {
          print('Parallel analysis failed, falling back to sequential: $e');
        }
        progressCallback?.call('Parallel analysis unavailable, using sequential...');
        // Fall through to sequential path.
      }
    }

    // ── SEQUENTIAL PATH (web, mobile, or parallel-fallback) ──────
    // Wait for the singleton Stockfish to initialise.
    int waited = 0;
    while (!_stockfish.isAvailable.value && waited < 50) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited++;
    }

    if (!_stockfish.isAvailable.value) {
      throw Exception(
        'Tactics analysis requires Stockfish, which is not available on this platform (web).\n\n'
        'You can:\n'
        '• Import tactics from a CSV file (exported from desktop)\n'
        '• Use the desktop app to generate tactics\n'
        '• Practice existing tactics positions'
      );
    }

    final positions = <TacticsPosition>[];

    for (final task in gameTasks) {
      final gameText = task['gameText'] as String;
      final globalIndex = task['globalIndex'] as int;
      final gameId = task['gameId'] as String;

      try {
        final game = PgnGame.parsePgn(gameText);

        final progressMsg =
            'Analyzing game $globalIndex/${games.length} (depth $depth)... '
            '${skippedCount > 0 ? "($skippedCount skipped)" : ""}';
        progressCallback?.call(progressMsg);
        if (kDebugMode) print(progressMsg);

        final white = game.headers['White']?.toLowerCase() ?? '';
        final black = game.headers['Black']?.toLowerCase() ?? '';

        chess.Color? userColor;
        if (white == usernameLower) {
          userColor = chess.Color.WHITE;
        } else if (black == usernameLower) {
          userColor = chess.Color.BLACK;
        } else if (white.contains(usernameLower)) {
          userColor = chess.Color.WHITE;
        } else if (black.contains(usernameLower)) {
          userColor = chess.Color.BLACK;
        } else {
          await _database.markGameAnalyzed(gameId);
          continue;
        }

        final gamePositions = <TacticsPosition>[];
        await _analyzeGame(game, userColor, depth, gamePositions, onPositionFound, gameId);
        positions.addAll(gamePositions);

        // Flush all positions from this game atomically so training
        // encounters them as a coherent block.
        if (onPositionFound != null) {
          for (final pos in gamePositions) {
            onPositionFound(pos);
          }
        }

        await _database.markGameAnalyzed(gameId);
      } catch (e) {
        if (kDebugMode) print('Error parsing game $globalIndex: $e');
        continue;
      }
    }

    if (skippedCount > 0) {
      progressCallback?.call(
        'Done! Analyzed ${gameTasks.length} new games, skipped $skippedCount already-analyzed games.',
      );
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
        
        // Skip analysis if position after move is terminal (checkmate, stalemate, etc.)
        // These positions can't be properly evaluated by Stockfish and would produce
        // misleading delta values (e.g., user delivering checkmate flagged as "blunder")
        if (chessGame.game_over) {
          if (kDebugMode) {
            print('Move $moveNumber. $san | Skipping: Game over after this move');
          }
          // Update move number and continue
          if (chessGame.turn == chess.Color.WHITE) {
            moveNumber++;
          }
          continue;
        }
        
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
        
        // Use Lichess [-1, +1] scale for classification
        final wcBefore = _winningChances(cpA);
        final wcAfter = _winningChances(cpB);
        
        final delta = wcBefore - wcAfter;
        
        // Lichess thresholds (from lila/modules/tree/src/main/Advice.scala)
        // Blunder: >= 0.3, Mistake: >= 0.2, Inaccuracy: >= 0.1
        final isBlunder = delta >= 0.3;
        final isMistake = delta >= 0.2 && delta < 0.3;
        
        // Use winPercent for display
        final wpBefore = _winPercent(cpA);
        final wpAfter = _winPercent(cpB);
        
        // Debug output for every move
        if (kDebugMode) {
          final status = isBlunder ? '⚠️ BLUNDER' : (isMistake ? '⚠ MISTAKE' : '✓');
          print('Move $moveNumber. $san | Before: ${cpA}cp (${wpBefore.toStringAsFixed(1)}%) → After: ${cpB}cp (${wpAfter.toStringAsFixed(1)}%) | Δ${delta.toStringAsFixed(3)} | $status');
        }
        
        if (isBlunder || isMistake) {
          // Found Blunder or Mistake!
          if (kDebugMode) {
            print('  → PV from Stockfish: ${evalA.pv}');
          }
          if (evalA.pv.isNotEmpty) {
            final bestMoveUci = evalA.pv.first;
            
            // Generate correct line from PV, extending for tactical sequences.
            // Convert all PV moves to SAN first, then build the line by
            // peeking ahead: only extend if the NEXT user move is also a
            // check (+), capture (x), or checkmate (#). Max 5 user moves.
            final allPvSan = <String>[];
            final tempGame = chess.Chess.fromFEN(fenBefore);
            
            for (final uci in evalA.pv) {
              final sanMove = _makeUciMoveAndGetSan(tempGame, uci);
              if (kDebugMode) {
                print('  → UCI: $uci → SAN: $sanMove');
              }
              if (sanMove == null) break;
              allPvSan.add(sanMove);
            }
            
            final correctLine = <String>[];
            const maxUserMoves = 5;
            
            if (allPvSan.isNotEmpty) {
              // Always include the first user move
              correctLine.add(allPvSan[0]);
              int userMoveCount = 1;
              
              // Extend while: current user move is tactical AND next
              // user move (2 ahead) is also tactical.
              int i = 0; // index of the last added user move
              while (userMoveCount < maxUserMoves) {
                final currentUserSan = allPvSan[i];
                final currentIsTactical = currentUserSan.contains('x') ||
                    currentUserSan.contains('+') ||
                    currentUserSan.contains('#');
                
                if (!currentIsTactical) break; // current move is quiet, stop
                
                // Need opponent response (i+1) and next user move (i+2)
                if (i + 2 >= allPvSan.length) break;
                
                final nextUserSan = allPvSan[i + 2];
                final nextIsTactical = nextUserSan.contains('x') ||
                    nextUserSan.contains('+') ||
                    nextUserSan.contains('#');
                
                if (!nextIsTactical) break; // next user move is quiet, stop
                
                // Both are tactical — extend the line
                correctLine.add(allPvSan[i + 1]); // opponent response
                correctLine.add(nextUserSan);      // next user move
                userMoveCount++;
                i += 2;
              }
            }
            
            if (kDebugMode) {
              print('  → correctLine: $correctLine');
            }
            
            // Format best move SAN for display
            final bestMoveSan = _formatUciToSan(fenBefore, bestMoveUci);

            // Opponent's best response after the user's bad move
            final opponentResponse = evalB.pv.isNotEmpty
                ? _formatUciToSan(fenAfter, evalB.pv.first)
                : '';

            final chanceA = wpBefore.toStringAsFixed(1);
            final chanceB = wpAfter.toStringAsFixed(1);
            final mistakeType = isBlunder ? '??' : '?';
            final label = isBlunder ? 'Blunder' : 'Mistake';
            final analysis = '$label. Win chance dropped from $chanceA% to $chanceB% (${delta.toStringAsFixed(1)}%). Best was $bestMoveSan.';

            final tacticsPosition = TacticsPosition(
              fen: fenBefore,
              userMove: san,
              correctLine: correctLine,
              mistakeType: mistakeType,
              mistakeAnalysis: analysis,
              opponentBestResponse: opponentResponse,
              positionContext: 'Move $moveNumber, ${userColor == chess.Color.WHITE ? 'White' : 'Black'} to play',
              gameWhite: game.headers['White'] ?? '',
              gameBlack: game.headers['Black'] ?? '',
              gameResult: game.headers['Result'] ?? '*',
              gameDate: game.headers['Date'] ?? '',
              gameId: gameId, // Use the same ID we used for skip-detection
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
