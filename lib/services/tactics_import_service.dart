import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import '../constants/engine_defaults.dart';
import '../models/tactics_position.dart';
import 'tactics_engine.dart';
import '../models/engine_settings.dart';
import 'engine/stockfish_pool.dart';
import 'chess_api_urls.dart';
import 'lichess_api_client.dart';
import 'maia_factory.dart';
import 'tactics_database.dart';
import 'pgn_parsing_service.dart';
import 'storage/storage_factory.dart';
import '../utils/chesscom_lichess_elo.dart';
import '../utils/log.dart';
import '../utils/movetext_builder.dart';
import 'tactics_parallel_analyzer_stub.dart'
    if (dart.library.io) 'tactics_parallel_analyzer.dart'
    as parallel;

part 'tactics_import_analysis.dart';
part 'tactics_import_pgn_helpers.dart';

/// Callback for when a new tactics position is found during import.
/// Returns a Future so callers can await persistence before proceeding.
typedef OnPositionFoundCallback =
    Future<void> Function(TacticsPosition position);

/// Callback for progress updates during import
typedef ProgressCallback = void Function(String message);

/// Result of a tactics import or resume operation.
typedef ImportResult = ({
  List<TacticsPosition> positions,
  int gamesAnalyzed,
  int gamesSkipped,
});

class TacticsImportService {
  TacticsImportService({TacticsDatabase? database})
    : _database = database ?? TacticsDatabase();

  final TacticsDatabase _database;

  /// Whether to skip games that have already been analyzed
  bool skipAnalyzedGames = true;

  bool _cancelled = false;

  /// Signal the current import to stop after the current game finishes.
  void cancel() {
    _cancelled = true;
    StockfishPool.instance.stopAll();
  }

  /// Whether the last import/resume run was cancelled via [cancel].
  bool get wasCancelled => _cancelled;

  /// Check if engine-based analysis is available on this platform
  bool get isAnalysisAvailable =>
      StockfishPool.instance.workerCount > 0 ||
      parallel.isParallelAnalysisAvailable;

  /// Whether parallel multi-core analysis is available (desktop only).
  static bool get isParallelAvailable => parallel.isParallelAnalysisAvailable;

  /// Number of logical CPU cores on this machine.
  static int get availableCores => parallel.availableProcessors;

  /// Count stored PGN games that have not yet been analyzed.
  ///
  /// Returns `(total, pending)` where `total` is the number of distinct game
  /// PGNs in storage and `pending` is how many of those lack an entry in
  /// [TacticsDatabase.analyzedGameIds]. Only counts games for platforms that
  /// have a configured username, since resume cannot process others. Games
  /// played before [since] are treated as expired: not pending, and
  /// [resumeStoredPgns] applies the same window so count and behavior agree.
  Future<({int total, int pending})> countPendingGames({
    String? lichessUsername,
    String? chesscomUsername,
    DateTime? since,
  }) async {
    final content = await StorageFactory.instance.readImportedPgns();
    if (content == null || content.isEmpty) return (total: 0, pending: 0);

    final hasLichess = lichessUsername != null && lichessUsername.isNotEmpty;
    final hasChessCom = chesscomUsername != null && chesscomUsername.isNotEmpty;

    final games = splitPgnIntoGames(content);
    int pending = 0;
    for (final game in games) {
      final gameId = _extractGameId(game);
      if (gameId.isEmpty || _isGameAnalyzed(gameId)) continue;
      if (since != null && _isGameBefore(game, since)) continue;
      // Only count games resume can actually process: a known platform
      // prefix with that platform's username configured.
      if (gameId.startsWith('lichess_') && hasLichess) pending++;
      if (gameId.startsWith('chesscom_') && hasChessCom) pending++;
    }
    return (total: games.length, pending: pending);
  }

  /// Remove stored PGNs that no longer serve the resume queue: games
  /// already analyzed, and games played before [since] (expired). Returns
  /// how many games were removed.
  ///
  /// The analyzed-IDs list is intentionally kept — it's a few bytes per
  /// game and is what prevents re-analysis when an overlapping date range
  /// is fetched again later.
  Future<int> pruneStoredPgns({DateTime? since}) async {
    final content = await StorageFactory.instance.readImportedPgns();
    if (content == null || content.isEmpty) return 0;

    final games = splitPgnIntoGames(content);
    final kept = <String>[];
    for (final game in games) {
      final gameId = _extractGameId(game);
      if (gameId.isNotEmpty && _isGameAnalyzed(gameId)) continue;
      if (since != null && _isGameBefore(game, since)) continue;
      kept.add(game);
    }
    if (kept.length == games.length) return 0;

    await StorageFactory.instance.saveImportedPgns(kept.join('\n\n'));
    if (kDebugMode) {
      log.i(
        'Pruned ${games.length - kept.length} stored PGNs '
        '(${kept.length} kept)',
      );
    }
    return games.length - kept.length;
  }

  /// Resume analysis of stored PGN games that haven't been analyzed yet.
  ///
  /// Reads saved PGNs from storage, splits them by source (Lichess vs
  /// Chess.com based on game ID prefix), and processes each batch with the
  /// appropriate username. Already-analyzed games are skipped automatically
  /// by [_processGames]. Games played before [since] are left untouched —
  /// the same window [countPendingGames] applies.
  Future<ImportResult> resumeStoredPgns({
    required String? lichessUsername,
    required String? chesscomUsername,
    required int depth,
    DateTime? since,
    int? maxCores,
    ProgressCallback? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    _cancelled = false;
    final content = await StorageFactory.instance.readImportedPgns();
    if (content == null || content.isEmpty) {
      return (
        positions: <TacticsPosition>[],
        gamesAnalyzed: 0,
        gamesSkipped: 0,
      );
    }

    final games = splitPgnIntoGames(content);
    final lichessGames = <String>[];
    final chessComGames = <String>[];
    int preFilterSkipped = 0;

    for (final game in games) {
      final gameId = _extractGameId(game);
      if (_isGameAnalyzed(gameId)) {
        preFilterSkipped++;
        continue;
      }
      if (since != null && _isGameBefore(game, since)) continue;

      if (gameId.startsWith('lichess_')) {
        lichessGames.add(game);
      } else if (gameId.startsWith('chesscom_')) {
        chessComGames.add(game);
      }
    }

    final allPositions = <TacticsPosition>[];
    int totalAnalyzed = 0;
    int totalSkipped = preFilterSkipped;

    if (lichessGames.isNotEmpty &&
        lichessUsername != null &&
        lichessUsername.isNotEmpty) {
      final result = await _processGames(
        lichessGames.join('\n\n'),
        lichessUsername,
        depth,
        progressCallback,
        onPositionFound,
        maxCores: maxCores,
        mapChessComEloForMaia: false,
      );
      allPositions.addAll(result.positions);
      totalAnalyzed += result.gamesAnalyzed;
      totalSkipped += result.gamesSkipped;
    }

    if (!_cancelled &&
        chessComGames.isNotEmpty &&
        chesscomUsername != null &&
        chesscomUsername.isNotEmpty) {
      final result = await _processGames(
        chessComGames.join('\n\n'),
        chesscomUsername,
        depth,
        progressCallback,
        onPositionFound,
        maxCores: maxCores,
        mapChessComEloForMaia: true,
      );
      allPositions.addAll(result.positions);
      totalAnalyzed += result.gamesAnalyzed;
      totalSkipped += result.gamesSkipped;
    }

    return (
      positions: allPositions,
      gamesAnalyzed: totalAnalyzed,
      gamesSkipped: totalSkipped,
    );
  }

  /// Initialize the database (load analyzed game IDs).
  /// Called by the coordinator before import; safe to call multiple times.
  Future<void> initialize() async {
    if (_database.positions.isEmpty && _database.analyzedGameIds.isEmpty) {
      await _database.loadPositions();
    }
  }

  Future<ImportResult> importGamesFromLichess(
    String username, {
    int? maxGames,
    DateTime? since,
    int depth = 15,
    int? maxCores,
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    _cancelled = false;
    final params = <String, String>{
      'evals': 'false',
      'clocks': 'false',
      'opening': 'false',
      'moves': 'true',
    };
    if (since != null) {
      params['since'] = '${since.millisecondsSinceEpoch}';
      params['max'] = '${maxGames ?? 200}';
    } else {
      params['max'] = '${maxGames ?? 20}';
    }
    final url = lichessUserGamesUrl(username, params);

    progressCallback?.call('Downloading games from Lichess...');
    final response = await LichessApiClient.instance.get(
      url,
      extraHeaders: {'Accept': 'application/x-chess-pgn'},
    );

    if (response == null) {
      throw Exception('Failed to fetch games from Lichess (request failed)');
    }
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch games from Lichess: ${response.statusCode}',
      );
    }

    await _savePgns(response.body);
    return _processGames(
      response.body,
      username,
      depth,
      progressCallback,
      onPositionFound,
      maxCores: maxCores,
      mapChessComEloForMaia: false,
    );
  }

  /// Fetch the list of monthly archive URLs from Chess.com.
  ///
  /// Returns the URLs in chronological order (oldest first), or an empty
  /// list if the player has no archives.
  Future<List<String>> _fetchChesscomArchives(String username) async {
    final url = chesscomArchivesUrl(username);
    final response = await http.get(url);
    if (response.statusCode != 200) return [];
    final data = json.decode(response.body) as Map<String, dynamic>;
    return List<String>.from(data['archives'] as List);
  }

  Future<ImportResult> importGamesFromChessCom(
    String username, {
    int? maxGames,
    DateTime? since,
    int depth = 15,
    int? maxCores,
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound,
  }) async {
    _cancelled = false;
    int targetGames = maxGames ?? (since != null ? 200 : 10);
    List<String> allGames = [];

    progressCallback?.call('Fetching Chess.com game archives for $username…');

    // Use the archives endpoint to discover which months actually have
    // games, rather than blindly checking the last N months (which fails
    // for inactive players).
    final archives = await _fetchChesscomArchives(username);

    if (archives.isEmpty) {
      throw Exception('No game archives found for $username on Chess.com');
    }

    // When fetching since a date, skip archive months before that date.
    // Archive URLs are like https://api.chess.com/pub/player/.../games/2024/06
    int startArchiveIndex = 0;
    if (since != null) {
      final sinceYear = since.year;
      final sinceMonth = since.month;
      for (int i = 0; i < archives.length; i++) {
        final parts = archives[i].split('/');
        if (parts.length >= 2) {
          final year = int.tryParse(parts[parts.length - 2]);
          final month = int.tryParse(parts[parts.length - 1]);
          if (year != null && month != null) {
            if (year > sinceYear ||
                (year == sinceYear && month >= sinceMonth)) {
              startArchiveIndex = i;
              break;
            }
          }
        }
      }
    }

    // Walk backwards from the most recent archive.
    for (
      int i = archives.length - 1;
      i >= startArchiveIndex && allGames.length < targetGames && !_cancelled;
      i--
    ) {
      progressCallback?.call(
        'Downloading Chess.com games (${allGames.length}/$targetGames)…',
      );

      try {
        final response = await http.get(Uri.parse('${archives[i]}/pgn'));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          final games = splitPgnIntoGames(response.body);
          allGames.addAll(games);
        }
      } catch (e) {
        if (kDebugMode) log.e('Error fetching Chess.com games: $e');
      }
    }

    if (allGames.isEmpty) {
      if (_cancelled) {
        return (
          positions: <TacticsPosition>[],
          gamesAnalyzed: 0,
          gamesSkipped: 0,
        );
      }
      throw Exception('No games found for $username on Chess.com');
    }

    // Filter out games older than the since date by parsing PGN Date header.
    if (since != null) {
      allGames = allGames.where((g) => !_isGameBefore(g, since)).toList();
    }

    // Limit to target games
    final gamesToProcess = allGames.take(targetGames).join('\n\n');

    // Save the raw PGNs first
    await _savePgns(gamesToProcess);

    return _processGames(
      gamesToProcess,
      username,
      depth,
      progressCallback,
      onPositionFound,
      maxCores: maxCores,
      mapChessComEloForMaia: true,
    );
  }

  /// Save raw PGNs to storage with GameId headers injected.
  ///
  /// Appends to existing PGNs, skipping any games whose GameId already
  /// appears in the stored file.
  Future<void> _savePgns(String pgnContent) async {
    try {
      final games = splitPgnIntoGames(pgnContent);
      final processedGames = games.map(_injectGameIdHeader).toList();

      final existing = await StorageFactory.instance.readImportedPgns() ?? '';

      // Collect GameIds already in storage to avoid duplicates
      final existingIds = <String>{};
      if (existing.isNotEmpty) {
        for (final match in RegExp(
          r'\[GameId "([^"]+)"\]',
        ).allMatches(existing)) {
          existingIds.add(match.group(1)!);
        }
      }

      // Only append games not already stored
      final newGames = processedGames.where((game) {
        final idMatch = RegExp(r'\[GameId "([^"]+)"\]').firstMatch(game);
        return idMatch == null || !existingIds.contains(idMatch.group(1));
      }).toList();

      if (newGames.isEmpty) {
        if (kDebugMode) {
          log.i(
            'All ${games.length} PGNs already in storage, nothing to append',
          );
        }
        return;
      }

      final newContent = existing.isEmpty
          ? newGames.join('\n\n')
          : '$existing\n\n${newGames.join('\n\n')}';
      await StorageFactory.instance.saveImportedPgns(newContent);

      if (kDebugMode) {
        log.w(
          'Appended ${newGames.length} new PGNs to storage (${games.length - newGames.length} duplicates skipped)',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        log.e('Error saving PGNs: $e');
      }
    }
  }

  /// Whether [gameId] was already analyzed, accepting legacy records: builds
  /// that trusted Lichess's native GameId header stored those IDs without
  /// the `lichess_` prefix.
  bool _isGameAnalyzed(String gameId) {
    if (_database.isGameAnalyzed(gameId)) return true;
    const prefix = 'lichess_';
    return gameId.startsWith(prefix) &&
        _database.isGameAnalyzed(gameId.substring(prefix.length));
  }

  Future<ImportResult> _processGames(
    String pgnContent,
    String username,
    int depth,
    Function(String)? progressCallback,
    OnPositionFoundCallback? onPositionFound, {
    int? maxCores,

    /// When true, PGN [WhiteElo]/[BlackElo] are Chess.com blitz and converted
    /// via [chessComBlitzToLichessBlitz] before Maia line extension.
    bool mapChessComEloForMaia = false,
  }) async {
    // A cancel during the fetch/download phase must stick — resetting
    // `_cancelled` here used to silently un-cancel the run once analysis
    // started. The flag is reset by the public run entry points instead.
    if (_cancelled) {
      return (
        positions: <TacticsPosition>[],
        gamesAnalyzed: 0,
        gamesSkipped: 0,
      );
    }
    final games = splitPgnIntoGames(pgnContent);
    final usernameLower = username.toLowerCase();

    // ── Pre-filter: skip already-analyzed games ──────────────
    final gameTasks = <Map<String, dynamic>>[];
    int skippedCount = 0;

    for (int i = 0; i < games.length; i++) {
      final gameId = _extractGameId(games[i]);
      if (skipAnalyzedGames && _isGameAnalyzed(gameId)) {
        skippedCount++;
        if (kDebugMode) log.w('Skipping already-analyzed game: $gameId');
        continue;
      }
      gameTasks.add({
        'gameText': games[i],
        'globalIndex': i + 1,
        'gameId': gameId,
      });
    }

    if (gameTasks.isNotEmpty) {
      final n = gameTasks.length;
      progressCallback?.call(
        '$n new game${n == 1 ? '' : 's'} found, analyzing…',
      );
    }

    if (gameTasks.isEmpty) {
      progressCallback?.call(
        'No new games to analyze — you\'re all caught up!',
      );
      return (
        positions: <TacticsPosition>[],
        gamesAnalyzed: 0,
        gamesSkipped: skippedCount,
      );
    }

    // ── Initialize Maia for line extension (desktop only) ────
    MaiaEvaluator? maia;
    int maiaElo = kDefaultMaiaElo;
    if (MaiaFactory.isAvailable) {
      maia = MaiaFactory.instance;
      if (maia != null) {
        try {
          await maia.initialize();
        } catch (e) {
          if (kDebugMode) log.e('Maia init failed, falling back: $e');
          maia = null;
        }
      }
      if (maia != null) {
        final firstGame = gameTasks.first['gameText'] as String;
        final userElo = _extractUserElo(firstGame, usernameLower);
        if (userElo != null) {
          final lichessElo = mapChessComEloForMaia
              ? chessComBlitzToLichessBlitz(userElo)
              : userElo;
          maiaElo = lichessElo.clamp(kMinMaiaElo, kMaxMaiaElo);
        }
        if (kDebugMode) log.d('Maia line extension enabled (Elo=$maiaElo)');
      }
    }

    // ── Ensure the shared pool has enough workers ─────────────
    final pool = StockfishPool.instance;
    final targetWorkers = maxCores ?? EngineSettings.instance.workers;
    await pool.ensureWorkers(targetWorkers);

    if (pool.workerCount == 0) {
      throw Exception(
        'Tactics analysis requires Stockfish, which is not available '
        'on this platform.\n\n'
        'You can:\n'
        '• Import tactics from a CSV file (exported from desktop)\n'
        '• Use the desktop app to generate tactics\n'
        '• Practice existing tactics positions',
      );
    }

    // The pool is a shared singleton; other features (e.g. tree generation)
    // may have left workers configured with multiple UCI threads each.
    // Tactics analysis wants throughput across many independent positions, so
    // force one thread per worker: N single-threaded workers beat N/T
    // multi-threaded ones and avoid CPU oversubscription.
    await pool.reconfigureAllWorkers(1);

    final concurrency = math.min(pool.workerCount, gameTasks.length);

    progressCallback?.call(
      'Starting analysis: ${gameTasks.length} games '
      'across $concurrency workers...',
    );

    // ── Build lookup for original game order ─────────────────
    final gameOrder = <String, int>{};
    for (int i = 0; i < gameTasks.length; i++) {
      gameOrder[gameTasks[i]['gameId'] as String] = i;
    }

    // ── Process games in parallel (dynamic work-stealing) ────
    final gamePositions = <String, List<TacticsPosition>>{};
    int completedGames = 0;
    int totalPositionsFound = 0;

    await pool.forEachParallel<Map<String, dynamic>>(gameTasks, (
      worker,
      task,
    ) async {
      final gameText = task['gameText'] as String;
      final gameId = task['gameId'] as String;

      try {
        final positions = await _analyzeGameWithWorker(
          worker: worker,
          gameText: gameText,
          username: usernameLower,
          depth: depth,
          gameId: gameId,
          maia: maia,
          maiaElo: maiaElo,
          shouldAbort: () => _cancelled,
        );
        if (_cancelled) return;
        gamePositions[gameId] = positions;
        totalPositionsFound += positions.length;

        // Persist positions BEFORE marking game analyzed so a
        // mid-analysis app close doesn't permanently skip this game.
        if (positions.isNotEmpty && onPositionFound != null) {
          for (final pos in positions) {
            await onPositionFound(pos);
          }
        }
        await _database.markGameAnalyzed(gameId);
      } catch (e) {
        if (_cancelled) return;
        if (kDebugMode) log.e('Error analyzing game $gameId: $e');
      }

      completedGames++;
      progressCallback?.call(
        'Analyzed $completedGames/${gameTasks.length} games '
        '($totalPositionsFound tactics found)...',
      );
    }, stopWhen: () => _cancelled);

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
    return (
      positions: positions,
      gamesAnalyzed: gameTasks.length,
      gamesSkipped: skippedCount,
    );
  }
}
