import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import '../models/tactics_position.dart';
import '../models/engine_settings.dart';
import 'engine/eval_worker.dart';
import 'engine/stockfish_pool.dart';
import 'lichess_api_client.dart';
import 'tactics_database.dart';
import 'storage/storage_factory.dart';
import 'tactics_parallel_analyzer_stub.dart'
    if (dart.library.io) 'tactics_parallel_analyzer.dart' as parallel;

/// Callback for when a new tactics position is found during import
typedef OnPositionFoundCallback = void Function(TacticsPosition position);

/// Callback for progress updates during import
typedef ProgressCallback = void Function(String message);

class TacticsImportService {
  final TacticsDatabase _database = TacticsDatabase();
  
  /// Whether to skip games that have already been analyzed
  bool skipAnalyzedGames = true;

  bool _cancelled = false;

  /// Signal the current import to stop after the current game finishes.
  void cancel() {
    _cancelled = true;
    StockfishPool().stopAll();
  }
  
  /// Check if engine-based analysis is available on this platform
  bool get isAnalysisAvailable =>
      StockfishPool().workerCount > 0 || parallel.isParallelAnalysisAvailable;

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
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    if (_database.analyzedGameIds.isEmpty) {
      await _database.loadPositions();
    }
    
    final url = Uri.parse('https://lichess.org/api/games/user/$username?max=${maxGames ?? 20}&evals=false&clocks=false&opening=false&moves=true');
    
    progressCallback?.call('Downloading games from Lichess...');
    final response = await LichessApiClient().get(
      url,
      extraHeaders: {'Accept': 'application/x-chess-pgn'},
    );

    if (response == null) {
      throw Exception('Failed to fetch games from Lichess (request failed)');
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch games from Lichess: ${response.statusCode}');
    }

    await _savePgns(response.body);
    return _processGames(response.body, username, depth, progressCallback, onPositionFound, maxCores: maxCores);
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
    
    return _processGames(gamesToProcess, username, depth, progressCallback, onPositionFound, maxCores: maxCores);
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
      final trimmed = line.trim();
      if (!addedGameId && trimmed.startsWith('[') && trimmed.endsWith(']')) {
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
  }) async {
    _cancelled = false;
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

    // ── Ensure the shared pool has enough workers ─────────────
    final pool = StockfishPool();
    final targetWorkers = maxCores ?? EngineSettings().workers;
    await pool.ensureWorkers(targetWorkers);

    if (pool.workerCount == 0) {
      throw Exception(
        'Tactics analysis requires Stockfish, which is not available '
        'on this platform.\n\n'
        'You can:\n'
        '• Import tactics from a CSV file (exported from desktop)\n'
        '• Use the desktop app to generate tactics\n'
        '• Practice existing tactics positions'
      );
    }

    final numWorkers = math.min(pool.workerCount, gameTasks.length);

    // Distribute games round-robin across workers.
    final workerBatches =
        List.generate(numWorkers, (_) => <Map<String, dynamic>>[]);
    for (int i = 0; i < gameTasks.length; i++) {
      workerBatches[i % numWorkers].add(gameTasks[i]);
    }

    progressCallback?.call(
      'Starting analysis: ${gameTasks.length} games '
      'across $numWorkers workers...',
    );

    // ── Build lookup for original game order ─────────────────
    final gameOrder = <String, int>{};
    for (int i = 0; i < gameTasks.length; i++) {
      gameOrder[gameTasks[i]['gameId'] as String] = i;
    }

    // ── Process each batch in parallel ───────────────────────
    final gamePositions = <String, List<TacticsPosition>>{};
    int completedGames = 0;
    int totalPositionsFound = 0;

    final futures = <Future<void>>[];
    for (final batch in workerBatches) {
      if (batch.isEmpty) continue;
      futures.add(() async {
        final worker = await pool.acquire();
        try {
          for (final task in batch) {
            if (_cancelled) break;

            final gameText = task['gameText'] as String;
            final gameId = task['gameId'] as String;

            try {
              final positions = await _analyzeGameWithWorker(
                worker: worker,
                gameText: gameText,
                username: usernameLower,
                depth: depth,
                gameId: gameId,
              );
              if (_cancelled) break;
              gamePositions[gameId] = positions;
              totalPositionsFound += positions.length;
            } catch (e) {
              if (_cancelled) break;
              if (kDebugMode) print('Error analyzing game $gameId: $e');
            }

            completedGames++;
            await _database.markGameAnalyzed(gameId);

            final gameTactics = gamePositions[gameId];
            if (gameTactics != null && onPositionFound != null) {
              for (final pos in gameTactics) {
                onPositionFound(pos);
              }
            }

            progressCallback?.call(
              'Analyzed $completedGames/${gameTasks.length} games '
              '($totalPositionsFound tactics found)...',
            );
          }
        } finally {
          pool.release(worker);
        }
      }());
    }

    await Future.wait(futures);

    // ── Assemble results in original game order ──────────────
    final sortedGameIds = gamePositions.keys.toList()
      ..sort((a, b) => (gameOrder[a] ?? 999).compareTo(gameOrder[b] ?? 999));

    final positions = <TacticsPosition>[];
    for (final gameId in sortedGameIds) {
      positions.addAll(gamePositions[gameId]!);
    }

    if (_cancelled) {
      // UI clears itself on cancel — no message needed.
    } else {
      progressCallback?.call(
        'Done! Analyzed ${gameTasks.length} games'
        '${skippedCount > 0 ? ', skipped $skippedCount' : ''}. '
        'Found ${positions.length} tactics positions.',
      );
    }
    return positions;
  }

  /// Analyze a single game using a pool worker. Returns discovered tactics.
  Future<List<TacticsPosition>> _analyzeGameWithWorker({
    required EvalWorker worker,
    required String gameText,
    required String username,
    required int depth,
    required String gameId,
  }) async {
    final game = PgnGame.parsePgn(gameText);

    final white = (game.headers['White'] ?? '').toLowerCase();
    final black = (game.headers['Black'] ?? '').toLowerCase();

    Side? userColor;
    if (white == username) {
      userColor = Side.white;
    } else if (black == username) {
      userColor = Side.black;
    } else if (white.contains(username)) {
      userColor = Side.white;
    } else if (black.contains(username)) {
      userColor = Side.black;
    }
    if (userColor == null) return [];

    final moves = <String>[];
    var node = game.moves;
    while (node.children.isNotEmpty) {
      final child = node.children.first;
      moves.add(child.data.san);
      node = child;
    }

    final positions = <TacticsPosition>[];
    Position pos = Chess.initial;
    int moveNumber = 1;

    for (final san in moves) {
      final isUserTurn = pos.turn == userColor;

      if (isUserTurn) {
        final evalA = await worker.evaluateFen(pos.fen, depth);

        final fenBefore = pos.fen;
        final move = pos.parseSan(san);
        if (move == null) break;
        pos = pos.play(move);

        if (pos.isGameOver) {
          if (pos.turn == Side.white) moveNumber++;
          continue;
        }

        final evalB = await worker.evaluateFen(pos.fen, depth);
        final fenAfter = pos.fen;

        // EvalWorker returns side-to-move perspective:
        //   evalA: user's turn  → already user's perspective
        //   evalB: opponent's turn → negate for user's perspective
        final cpA = evalA.effectiveCp;
        final cpB = -evalB.effectiveCp;

        final wcBefore = _winningChances(cpA);
        final wcAfter = _winningChances(cpB);
        final delta = wcBefore - wcAfter;

        final isBlunder = delta >= 0.3;
        final isMistake = delta >= 0.2 && delta < 0.3;

        if ((isBlunder || isMistake) && evalA.pv.isNotEmpty) {
          final bestMoveUci = evalA.pv.first;

          final allPvSan = <String>[];
          Position tempPos = Chess.fromSetup(Setup.parseFen(fenBefore));
          for (final uci in evalA.pv) {
            final (sanMove, newPos) = _makeUciMoveAndGetSan(tempPos, uci);
            if (sanMove == null) break;
            allPvSan.add(sanMove);
            tempPos = newPos;
          }

          final correctLine = <String>[];
          const maxUserMoves = 5;

          if (allPvSan.isNotEmpty) {
            correctLine.add(allPvSan[0]);
            int userMoveCount = 1;
            int i = 0;
            while (userMoveCount < maxUserMoves) {
              final currentUserSan = allPvSan[i];
              final currentIsTactical = currentUserSan.contains('x') ||
                  currentUserSan.contains('+') ||
                  currentUserSan.contains('#');
              if (!currentIsTactical) break;
              if (i + 2 >= allPvSan.length) break;
              final nextUserSan = allPvSan[i + 2];
              final nextIsTactical = nextUserSan.contains('x') ||
                  nextUserSan.contains('+') ||
                  nextUserSan.contains('#');
              if (!nextIsTactical) break;
              correctLine.add(allPvSan[i + 1]);
              correctLine.add(nextUserSan);
              userMoveCount++;
              i += 2;
            }
          }

          final bestMoveSan = _formatUciToSan(fenBefore, bestMoveUci);
          final opponentResponse = evalB.pv.isNotEmpty
              ? _formatUciToSan(fenAfter, evalB.pv.first)
              : '';

          final wpBefore = _winPercent(cpA);
          final wpAfter = _winPercent(cpB);
          final mistakeType = isBlunder ? '??' : '?';
          final label = isBlunder ? 'Blunder' : 'Mistake';
          final analysis =
              '$label. Win chance dropped from '
              '${wpBefore.toStringAsFixed(1)}% to '
              '${wpAfter.toStringAsFixed(1)}% '
              '(${delta.toStringAsFixed(1)}%). Best was $bestMoveSan.';

          positions.add(TacticsPosition(
            fen: fenBefore,
            userMove: san,
            correctLine: correctLine,
            mistakeType: mistakeType,
            mistakeAnalysis: analysis,
            opponentBestResponse: opponentResponse,
            positionContext:
                'Move $moveNumber, '
                '${userColor == Side.white ? 'White' : 'Black'} to play',
            gameWhite: game.headers['White'] ?? '',
            gameBlack: game.headers['Black'] ?? '',
            gameResult: game.headers['Result'] ?? '*',
            gameDate: game.headers['Date'] ?? '',
            gameId: gameId,
          ));
        }
      } else {
        final move = pos.parseSan(san);
        if (move != null) pos = pos.play(move);
      }

      if (pos.turn == Side.white) moveNumber++;
    }

    return positions;
  }

  (String? san, Position newPos) _makeUciMoveAndGetSan(Position pos, String uci) {
    final move = Move.parse(uci);
    if (move == null) return (null, pos);
    try {
      final (newPos, san) = pos.makeSan(move);
      return (san, newPos);
    } catch (_) {
      return (null, pos);
    }
  }

  String _formatUciToSan(String fen, String uci) {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final (san, _) = _makeUciMoveAndGetSan(pos, uci);
    return san ?? uci;
  }
}
