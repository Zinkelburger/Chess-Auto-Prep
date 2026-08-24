import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import '../../../constants/engine_defaults.dart';
import '../models/tactics_note.dart';
import '../models/tactics_position.dart';
import 'tactics_engine.dart';
import '../../../services/game_store/game_store.dart';
import '../../../services/game_store/game_store_service.dart';
import '../../../models/engine_settings.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/games_library/game_filter.dart'
    show dedupKeyForHeaders;
import '../../../services/games_library/game_review_store.dart';
import '../../../services/chess_api_urls.dart';
import '../../../services/lichess_api_client.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../services/eval_cache.dart';
import 'tactics_database.dart';
import '../../../services/pgn_parsing_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../utils/chesscom_lichess_elo.dart';
import '../../../utils/clock_utils.dart';
import '../../../utils/log.dart';
import '../../../utils/movetext_builder.dart';
import '../../../utils/pgn_comment_utils.dart';
import 'eval_series_annotator.dart';
import 'flaw_tagger.dart';
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

/// Structured progress for job displays. [fraction] spans the whole run:
/// completed games plus the in-flight game's evaluated share.
typedef GameProgressCallback =
    void Function(double fraction, int gamesDone, int gamesTotal);

/// One game finished its engine pass: how messy it was for the user, filed
/// under the games-library identity of the game. Fires for clean games too —
/// "reviewed, nothing wrong" is a result, and the list has to be able to tell
/// it apart from "not reviewed yet".
typedef GameReviewedCallback =
    void Function(String dedupKey, ReviewCounts counts);

/// One game finished its engine pass with a usable per-ply score series, as a
/// drop-in replacement movetext carrying `[%eval]` comments.
///
/// The pass evaluates every position in the game on its way to the puzzles;
/// this is how those scores reach the games cache, so opening the game in the
/// viewer draws its graph from work already done instead of re-searching the
/// whole game. Does not fire for a game whose scores came out too sparse to
/// count as analyzed.
typedef GameAnnotatedCallback = void Function(String dedupKey, String movetext);

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

  /// GameIds referenced by a saved tactic in any tactics set on disk. The
  /// stored-PGN archive doubles as the source-game store for the tactics
  /// PGN tab (full game fast-forwarded to the tactic), so these games must
  /// survive pruning even after analysis.
  Future<Set<String>> _tacticReferencedGameIds() async {
    final ids = <String>{};
    final storage = StorageFactory.instance;
    final gameIdRe = RegExp(r'\[GameId "([^"]+)"\]');
    try {
      for (final set in await storage.listTacticsSets()) {
        final content = await storage.readFile(set.filePath);
        if (content == null) continue;
        for (final match in gameIdRe.allMatches(content)) {
          ids.add(match.group(1)!);
        }
      }
    } catch (e) {
      if (kDebugMode) log.w('Reading tactic gameIds for prune failed: $e');
    }
    return ids;
  }

  /// Remove stored PGNs that no longer serve the resume queue: games
  /// already analyzed, and games played before [since] (expired). Games a
  /// saved tactic references are always kept — the tactics PGN tab shows
  /// them as the full source game. Returns how many games were removed.
  ///
  /// The analyzed-IDs list is intentionally kept — it's a few bytes per
  /// game and is what prevents re-analysis when an overlapping date range
  /// is fetched again later.
  Future<int> pruneStoredPgns({DateTime? since}) async {
    final store = await GameStoreService.instance.open();
    final games = store.summaries(GameCollections.tactics);
    if (games.isEmpty) return 0;

    final referenced = await _tacticReferencedGameIds();
    final remove = <String>[];
    for (final summary in games) {
      final game = summary.headerBlock;
      final gameId = _extractGameId(game);
      if (gameId.isNotEmpty && referenced.contains(gameId)) continue;
      if (gameId.isNotEmpty && _isGameAnalyzed(gameId)) {
        remove.add(summary.key);
        continue;
      }
      if (since != null && _isGameBefore(game, since)) remove.add(summary.key);
    }
    if (remove.isEmpty) return 0;

    final removed = store.deleteKeys(GameCollections.tactics, remove);
    if (kDebugMode) {
      log.i(
        'Pruned $removed stored PGNs '
        '(${games.length - removed} kept)',
      );
    }
    return removed;
  }

  /// Resume analysis of stored PGN games that haven't been analyzed yet.
  ///
  /// Reads saved PGNs from storage, splits them by source (Lichess vs
  /// Chess.com based on game ID prefix), and processes each batch with the
  /// appropriate username. Already-analyzed games are skipped automatically
  /// by [_processGames]. Games played before [since] are left untouched —
  /// the same window pruning applies.
  Future<ImportResult> resumeStoredPgns({
    required String? lichessUsername,
    required String? chesscomUsername,
    required int depth,
    DateTime? since,
    int? maxCores,
    ProgressCallback? progressCallback,
    OnPositionFoundCallback? onPositionFound,
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
  }) async {
    _cancelled = false;
    final store = await GameStoreService.instance.open();
    final stored = store.list(GameCollections.tactics);
    if (stored.isEmpty) {
      return (
        positions: <TacticsPosition>[],
        gamesAnalyzed: 0,
        gamesSkipped: 0,
      );
    }

    final games = [for (final g in stored) g.pgn];
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
        onGameProgress: onGameProgress,
        onGameReviewed: onGameReviewed,
        onGameAnnotated: onGameAnnotated,
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
        onGameProgress: onGameProgress,
        onGameReviewed: onGameReviewed,
        onGameAnnotated: onGameAnnotated,
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

  /// Review games that have already been downloaded — the recent-games list's
  /// own copy of them.
  ///
  /// The review used to fetch every game twice: once into the games-library
  /// cache for the list, and again here for the engine pass. Same API, same
  /// window, two round trips, and two slices that could disagree about which
  /// games "recent" meant. This takes the PGNs the list already holds instead.
  ///
  /// They still go through [_savePgns] first: that is what injects the GameId
  /// headers, feeds the resume queue, and keeps the source game available to
  /// the puzzles mined from it.
  ///
  /// [forceDedupKeys] names games that must be analyzed even though the
  /// database has them marked analyzed — see [_processGames].
  Future<ImportResult> reviewFetchedGames({
    required String pgnContent,
    required String username,
    required int depth,
    int? maxCores,
    bool mapChessComEloForMaia = false,
    Set<String> forceDedupKeys = const {},
    ProgressCallback? progressCallback,
    OnPositionFoundCallback? onPositionFound,
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
  }) async {
    _cancelled = false;
    await _savePgns(pgnContent);
    return _processGames(
      pgnContent,
      username,
      depth,
      progressCallback,
      onPositionFound,
      maxCores: maxCores,
      mapChessComEloForMaia: mapChessComEloForMaia,
      forceDedupKeys: forceDedupKeys,
      onGameProgress: onGameProgress,
      onGameReviewed: onGameReviewed,
      onGameAnnotated: onGameAnnotated,
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
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
  }) async {
    _cancelled = false;
    final params = <String, String>{
      'evals': 'false',
      // Clocks feed the tempo flaw tags (low-clock/hasty/unrushed).
      'clocks': 'true',
      'opening': 'false',
      'moves': 'true',
    };
    if (since != null) {
      params['since'] = '${since.millisecondsSinceEpoch}';
      // No 'max' when the caller gave none: the since window is the limit,
      // and capping it would silently drop games the user asked for.
      if (maxGames != null) params['max'] = '$maxGames';
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
      onGameProgress: onGameProgress,
      onGameReviewed: onGameReviewed,
      onGameAnnotated: onGameAnnotated,
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
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
  }) async {
    _cancelled = false;
    // null = no game-count limit: the since window is the only limit. Only
    // the countless "latest N games" mode falls back to a default.
    final int? targetGames = maxGames ?? (since != null ? null : 10);
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
      i >= startArchiveIndex &&
          (targetGames == null || allGames.length < targetGames) &&
          !_cancelled;
      i--
    ) {
      progressCallback?.call(
        targetGames == null
            ? 'Downloading Chess.com games (${allGames.length})…'
            : 'Downloading Chess.com games (${allGames.length}/$targetGames)…',
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

    // Limit to target games (no limit when the since window governs).
    final gamesToProcess =
        (targetGames == null ? allGames : allGames.take(targetGames)).join(
          '\n\n',
        );

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
      onGameProgress: onGameProgress,
      onGameReviewed: onGameReviewed,
      onGameAnnotated: onGameAnnotated,
    );
  }

  /// Save raw PGNs to the games database with GameId headers injected.
  ///
  /// Append-only: a game whose GameId is already stored is left as it is
  /// (it may carry annotations the viewer wrote since).
  Future<void> _savePgns(String pgnContent) async {
    try {
      final games = splitPgnIntoGames(pgnContent);
      final processedGames = games.map(_injectGameIdHeader).toList();
      final store = await GameStoreService.instance.open();
      final result = store.importChunks(
        processedGames,
        collection: GameCollections.tactics,
        keepExisting: true,
      );

      if (kDebugMode) {
        if (result.inserted == 0) {
          log.i(
            'All ${games.length} PGNs already in storage, nothing to append',
          );
        } else {
          log.w(
            'Appended ${result.inserted} new PGNs to storage '
            '(${result.skipped} duplicates skipped)',
          );
        }
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

    /// Games — by [dedupKeyForHeaders] identity — that must be analyzed even
    /// if the database already has them marked analyzed.
    ///
    /// "Analyzed" only ever meant "its puzzles were mined". A game mined by an
    /// older build, or through the tactics import panel, was never asked for
    /// the mistake counts the recent-games list shows, and the pre-filter below
    /// then skipped it forever: the list said "12 games to analyse", the run
    /// said "you're all caught up", and the number never moved. Naming those
    /// games here is what gets them looked at.
    Set<String> forceDedupKeys = const {},
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
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
      final forced =
          forceDedupKeys.isNotEmpty &&
          forceDedupKeys.contains(dedupKeyForHeaders(extractHeaders(games[i])));
      if (skipAnalyzedGames && !forced && _isGameAnalyzed(gameId)) {
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

    progressCallback?.call(
      'Starting analysis: ${gameTasks.length} games '
      'across ${pool.workerCount} workers...',
    );

    // ── Process games one at a time, evaluations pool-wide ───
    // Each game's positions fan out across every worker (see
    // _analyzeGameParallel), so a single new game — the common incremental
    // import — already saturates the pool; running games concurrently on
    // top of that would only interleave their work. Sequential games also
    // keep today's cancel/resume granularity: a game is marked analyzed
    // only once its tactics are persisted, in original order.
    final evalCache = _OpeningEvalCache(depth: depth);
    final positions = <TacticsPosition>[];
    int completedGames = 0;
    int totalPositionsFound = 0;

    onGameProgress?.call(0, 0, gameTasks.length);
    for (final task in gameTasks) {
      if (_cancelled) break;
      final gameText = task['gameText'] as String;
      final gameId = task['gameId'] as String;

      try {
        final outcome = await _analyzeGameParallel(
          pool: pool,
          gameText: gameText,
          username: usernameLower,
          depth: depth,
          gameId: gameId,
          maia: maia,
          maiaElo: maiaElo,
          evalCache: evalCache,
          shouldAbort: () => _cancelled,
          onSiteProgress: (done, total) {
            progressCallback?.call(
              'Analyzing game ${completedGames + 1}/${gameTasks.length} '
              '(move $done/$total, $totalPositionsFound tactics found)...',
            );
            onGameProgress?.call(
              (completedGames + done / total) / gameTasks.length,
              completedGames,
              gameTasks.length,
            );
          },
        );
        if (_cancelled) break;
        final gamePositions = outcome?.positions ?? const <TacticsPosition>[];
        positions.addAll(gamePositions);
        totalPositionsFound += gamePositions.length;

        // Persist positions BEFORE marking game analyzed so a
        // mid-analysis app close doesn't permanently skip this game.
        if (gamePositions.isNotEmpty && onPositionFound != null) {
          for (final pos in gamePositions) {
            await onPositionFound(pos);
          }
        }
        // The same pass that found the puzzles also knows how messy the game
        // was; report it so the games list never needs a second engine pass.
        if (outcome != null) {
          onGameReviewed?.call(
            outcome.dedupKey,
            ReviewCounts(
              inaccuracies: outcome.inaccuracies,
              mistakes: outcome.mistakes,
              blunders: outcome.blunders,
            ),
          );
          // The same pass scored every position on the way to those counts;
          // hand the series over so the games cache can carry it.
          final annotated = outcome.annotatedMovetext;
          if (annotated != null) {
            onGameAnnotated?.call(outcome.dedupKey, annotated);
          }
        }
        await _database.markGameAnalyzed(gameId);
      } catch (e) {
        if (_cancelled) break;
        if (kDebugMode) log.e('Error analyzing game $gameId: $e');
      }

      completedGames++;
      progressCallback?.call(
        'Analyzed $completedGames/${gameTasks.length} games '
        '($totalPositionsFound tactics found)...',
      );
      onGameProgress?.call(
        completedGames / gameTasks.length,
        completedGames,
        gameTasks.length,
      );
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
