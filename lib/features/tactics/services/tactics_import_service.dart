/// Fetches my games from Lichess / Chess.com (or takes them already fetched),
/// keeps them in the tactics game store, and runs the engine pass that mines
/// puzzles from them — see [TacticsGameAnalyzer] for the pass itself.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../constants/engine_defaults.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/game_store/game_store.dart';
import '../../../services/game_store/game_store_service.dart';
import '../../../services/games_library/game_filter.dart'
    show dedupKeyForHeaders;
import '../../../services/games_library/game_review_store.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../chess_core/pgn/pgn_text.dart';
import '../../../utils/chesscom_lichess_elo.dart';
import '../../../utils/log.dart';
import '../models/tactics_position.dart';
import 'opening_eval_cache.dart';
import 'tactics_database.dart';
import 'tactics_game_fetcher.dart';
import 'tactics_game_pruner.dart';
import 'tactics_import_analysis.dart';
import 'tactics_import_pgn_helpers.dart';
import 'tactics_parallel_analyzer_stub.dart'
    if (dart.library.io) 'tactics_parallel_analyzer.dart'
    as parallel;

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

const ImportResult _emptyResult = (
  positions: <TacticsPosition>[],
  gamesAnalyzed: 0,
  gamesSkipped: 0,
);

/// Everything a run reports back to whoever started it.
class _RunListeners {
  const _RunListeners({
    this.progress,
    this.onPositionFound,
    this.onGameProgress,
    this.onGameReviewed,
    this.onGameAnnotated,
  });

  final ProgressCallback? progress;
  final OnPositionFoundCallback? onPositionFound;
  final GameProgressCallback? onGameProgress;
  final GameReviewedCallback? onGameReviewed;
  final GameAnnotatedCallback? onGameAnnotated;
}

/// One game queued for the engine pass.
typedef _GameTask = ({String gameText, String gameId});

class TacticsImportService {
  TacticsImportService({TacticsDatabase? database, required this.pool})
    : _database = database ?? TacticsDatabase();

  final TacticsDatabase _database;

  /// The engine pool this run evaluates on — the app-wide singleton in
  /// production, a scripted fake in tests. Injectable because everything
  /// [TacticsGameAnalyzer] decides (which swings become puzzles, which
  /// searches are skipped, what the annotated movetext says) is otherwise
  /// only reachable by starting real Stockfish processes.
  @visibleForTesting
  final StockfishPool pool;

  /// Downloads games for [importGamesFromLichess] / [importGamesFromChessCom].
  final TacticsGameFetcher fetcher = const TacticsGameFetcher();

  /// Whether to skip games that have already been analyzed
  bool skipAnalyzedGames = true;

  bool _cancelled = false;

  /// Whether [beginRun] has opened a run on this service.
  bool _runOpen = false;

  /// Open a run. From this moment a [cancel] sticks: nothing clears the flag
  /// again for the life of this service.
  ///
  /// The public entry points call this themselves, so a caller that simply
  /// awaits one needs nothing extra. A caller that becomes *cancellable
  /// before* it reaches an entry point calls it first — the tactics
  /// coordinator publishes its job and lights the Pause button synchronously,
  /// then awaits [initialize] (a file read plus an off-isolate decode) before
  /// it ever reaches [reviewFetchedGames]. Clearing the flag inside the entry
  /// point threw away every pause raised in that gap, and because the
  /// coordinator keeps `isCancelling` set once clicked, it also left the run
  /// uncancellable for the rest of its life.
  ///
  /// Idempotent for exactly that reason. The invariant: **a cancel raised at
  /// any point after the user can see the Pause button is honoured.**
  void beginRun() {
    if (_runOpen) return;
    _runOpen = true;
    _cancelled = false;
  }

  /// Signal the current import to stop after the current game finishes.
  void cancel() {
    _cancelled = true;
    pool.stopAll();
  }

  /// Whether the last import/resume run was cancelled via [cancel].
  bool get wasCancelled => _cancelled;

  /// Number of logical CPU cores on this machine.
  static int get availableCores => parallel.availableProcessors;

  /// Remove stored PGNs that no longer serve the resume queue — see
  /// [TacticsGamePruner.prune]. Refuses while the database could not be read,
  /// since "analyzed" is then unknown.
  Future<int> pruneStoredPgns({DateTime? since}) {
    final loadError = _database.loadError;
    if (loadError != null) throw StateError(loadError);
    return const TacticsGamePruner().prune(
      isAnalyzed: _isGameAnalyzed,
      since: since,
    );
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
    beginRun();
    final store = await GameStoreService.instance.open();
    final stored = store.list(GameCollections.tactics);
    if (stored.isEmpty) return _emptyResult;

    final lichessGames = <String>[];
    final chessComGames = <String>[];
    var preFilterSkipped = 0;
    for (final game in stored.map((g) => g.pgn)) {
      final gameId = extractGameId(game);
      if (_isGameAnalyzed(gameId)) {
        preFilterSkipped++;
        continue;
      }
      if (since != null && isGameBefore(game, since)) continue;
      if (gameId.startsWith(lichessGameIdPrefix)) {
        lichessGames.add(game);
      } else if (gameId.startsWith(chesscomGameIdPrefix)) {
        chessComGames.add(game);
      }
    }

    final listeners = _RunListeners(
      progress: progressCallback,
      onPositionFound: onPositionFound,
      onGameProgress: onGameProgress,
      onGameReviewed: onGameReviewed,
      onGameAnnotated: onGameAnnotated,
    );
    final positions = <TacticsPosition>[];
    var analyzed = 0;
    var skipped = preFilterSkipped;

    Future<void> processBatch(
      List<String> games,
      String? username, {
      required bool mapChessComEloForMaia,
    }) async {
      if (games.isEmpty || username == null || username.isEmpty) return;
      final result = await _processGames(
        games.join('\n\n'),
        username,
        depth,
        listeners,
        maxCores: maxCores,
        mapChessComEloForMaia: mapChessComEloForMaia,
      );
      positions.addAll(result.positions);
      analyzed += result.gamesAnalyzed;
      skipped += result.gamesSkipped;
    }

    await processBatch(
      lichessGames,
      lichessUsername,
      mapChessComEloForMaia: false,
    );
    if (!_cancelled) {
      await processBatch(
        chessComGames,
        chesscomUsername,
        mapChessComEloForMaia: true,
      );
    }
    return (
      positions: positions,
      gamesAnalyzed: analyzed,
      gamesSkipped: skipped,
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
    beginRun();
    await _savePgns(pgnContent);
    return _processGames(
      pgnContent,
      username,
      depth,
      _RunListeners(
        progress: progressCallback,
        onPositionFound: onPositionFound,
        onGameProgress: onGameProgress,
        onGameReviewed: onGameReviewed,
        onGameAnnotated: onGameAnnotated,
      ),
      maxCores: maxCores,
      mapChessComEloForMaia: mapChessComEloForMaia,
      forceDedupKeys: forceDedupKeys,
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
    ProgressCallback? progressCallback,
    OnPositionFoundCallback? onPositionFound,
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
  }) async {
    beginRun();
    final pgn = await fetcher.fetchLichessPgn(
      username,
      maxGames: maxGames,
      since: since,
      progress: progressCallback,
    );
    await _savePgns(pgn);
    return _processGames(
      pgn,
      username,
      depth,
      _RunListeners(
        progress: progressCallback,
        onPositionFound: onPositionFound,
        onGameProgress: onGameProgress,
        onGameReviewed: onGameReviewed,
        onGameAnnotated: onGameAnnotated,
      ),
      maxCores: maxCores,
      mapChessComEloForMaia: false,
    );
  }

  Future<ImportResult> importGamesFromChessCom(
    String username, {
    int? maxGames,
    DateTime? since,
    int depth = 15,
    int? maxCores,
    ProgressCallback? progressCallback,
    OnPositionFoundCallback? onPositionFound,
    GameProgressCallback? onGameProgress,
    GameReviewedCallback? onGameReviewed,
    GameAnnotatedCallback? onGameAnnotated,
  }) async {
    beginRun();
    final games = await fetcher.fetchChesscomGames(
      username,
      maxGames: maxGames,
      since: since,
      progress: progressCallback,
      isCancelled: () => _cancelled,
    );
    // Empty only when the download was cancelled before any game arrived.
    if (games.isEmpty) return _emptyResult;
    final gamesToProcess = games.join('\n\n');
    await _savePgns(gamesToProcess);
    return _processGames(
      gamesToProcess,
      username,
      depth,
      _RunListeners(
        progress: progressCallback,
        onPositionFound: onPositionFound,
        onGameProgress: onGameProgress,
        onGameReviewed: onGameReviewed,
        onGameAnnotated: onGameAnnotated,
      ),
      maxCores: maxCores,
      mapChessComEloForMaia: true,
    );
  }

  /// Save raw PGNs to the games database with GameId headers injected.
  ///
  /// Append-only: a game whose GameId is already stored is left as it is
  /// (it may carry annotations the viewer wrote since).
  Future<void> _savePgns(String pgnContent) async {
    try {
      final games = splitPgnIntoGames(pgnContent);
      final processedGames = games.map(injectGameIdHeader).toList();
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
      if (kDebugMode) log.e('Error saving PGNs: $e');
      rethrow;
    }
  }

  /// Whether [gameId] was already analyzed, accepting legacy records: builds
  /// that trusted Lichess's native GameId header stored those IDs without
  /// the `lichess_` prefix.
  bool _isGameAnalyzed(String gameId) {
    if (_database.isGameAnalyzed(gameId)) return true;
    return gameId.startsWith(lichessGameIdPrefix) &&
        _database.isGameAnalyzed(gameId.substring(lichessGameIdPrefix.length));
  }

  /// Split [pgnContent] into the games still to analyze and count the ones
  /// skipped as already analyzed.
  ({List<_GameTask> tasks, int skipped}) _selectGamesToAnalyze(
    String pgnContent,
    Set<String> forceDedupKeys,
  ) {
    final tasks = <_GameTask>[];
    var skipped = 0;
    for (final gameText in splitPgnIntoGames(pgnContent)) {
      final gameId = extractGameId(gameText);
      final forced =
          forceDedupKeys.isNotEmpty &&
          forceDedupKeys.contains(
            dedupKeyForHeaders(extractHeaders(gameText), pgn: gameText),
          );
      if (skipAnalyzedGames && !forced && _isGameAnalyzed(gameId)) {
        skipped++;
        if (kDebugMode) log.w('Skipping already-analyzed game: $gameId');
        continue;
      }
      tasks.add((gameText: gameText, gameId: gameId));
    }
    return (tasks: tasks, skipped: skipped);
  }

  /// Maia for line extension (desktop only), tuned to the user's rating as
  /// read off [firstGame]; null when Maia is unavailable or failed to start.
  Future<({MaiaEvaluator? maia, int elo})> _prepareMaia(
    String firstGame,
    String username, {
    required bool mapChessComEloForMaia,
  }) async {
    if (!MaiaFactory.isAvailable) return (maia: null, elo: kDefaultMaiaElo);
    final maia = MaiaFactory.instance;
    if (maia == null) return (maia: null, elo: kDefaultMaiaElo);
    try {
      await maia.initialize();
    } catch (e) {
      if (kDebugMode) log.e('Maia init failed, falling back: $e');
      return (maia: null, elo: kDefaultMaiaElo);
    }
    var elo = kDefaultMaiaElo;
    final userElo = extractUserElo(firstGame, username);
    if (userElo != null) {
      final lichessElo = mapChessComEloForMaia
          ? chessComBlitzToLichessBlitz(userElo)
          : userElo;
      elo = lichessElo.clamp(kMinMaiaElo, kMaxMaiaElo);
    }
    if (kDebugMode) log.d('Maia line extension enabled (Elo=$elo)');
    return (maia: maia, elo: elo);
  }

  /// Bring the shared pool up to [maxCores] single-threaded workers.
  Future<void> _preparePool(int? maxCores) async {
    await pool.ensureWorkers(maxCores);
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
    // Tactics analysis wants throughput across many independent positions,
    // so force one thread per worker: N single-threaded workers beat N/T
    // multi-threaded ones and avoid CPU oversubscription.
    await pool.reconfigureAllWorkers(1);
  }

  /// Run the engine pass over the games in [pgnContent] that still need it.
  ///
  /// [mapChessComEloForMaia]: when true, PGN `WhiteElo`/`BlackElo` are
  /// Chess.com blitz and converted via [chessComBlitzToLichessBlitz] before
  /// Maia line extension.
  ///
  /// [forceDedupKeys]: games — by [dedupKeyForHeaders] identity — that must
  /// be analyzed even if the database already has them marked analyzed.
  /// "Analyzed" only ever meant "its puzzles were mined". A game mined by an
  /// older build, or through the tactics import panel, was never asked for
  /// the mistake counts the recent-games list shows, and the pre-filter then
  /// skipped it forever: the list said "12 games to analyse", the run said
  /// "you're all caught up", and the number never moved. Naming those games
  /// here is what gets them looked at.
  Future<ImportResult> _processGames(
    String pgnContent,
    String username,
    int depth,
    _RunListeners listeners, {
    int? maxCores,
    bool mapChessComEloForMaia = false,
    Set<String> forceDedupKeys = const {},
  }) async {
    // A cancel during the fetch/download phase must stick — resetting
    // `_cancelled` here used to silently un-cancel the run once analysis
    // started. The flag is reset by the public run entry points instead.
    if (_cancelled) return _emptyResult;

    final selection = _selectGamesToAnalyze(pgnContent, forceDedupKeys);
    final tasks = selection.tasks;
    if (tasks.isEmpty) {
      listeners.progress?.call(
        'No new games to analyze — you\'re all caught up!',
      );
      return (
        positions: <TacticsPosition>[],
        gamesAnalyzed: 0,
        gamesSkipped: selection.skipped,
      );
    }
    listeners.progress?.call(
      '${tasks.length} new game${tasks.length == 1 ? '' : 's'} found, '
      'analyzing…',
    );

    final usernameLower = username.toLowerCase();
    final maia = await _prepareMaia(
      tasks.first.gameText,
      usernameLower,
      mapChessComEloForMaia: mapChessComEloForMaia,
    );
    await _preparePool(maxCores);
    listeners.progress?.call(
      'Starting analysis: ${tasks.length} games '
      'across ${pool.workerCount} workers...',
    );

    // Games run one at a time, evaluations pool-wide: each game's positions
    // fan out across every worker, so a single new game — the common
    // incremental import — already saturates the pool; running games
    // concurrently on top of that would only interleave their work.
    // Sequential games also keep today's cancel/resume granularity: a game
    // is marked analyzed only once its tactics are persisted, in original
    // order.
    final analyzer = TacticsGameAnalyzer(
      pool: pool,
      depth: depth,
      maia: maia.maia,
      maiaElo: maia.elo,
      evalCache: OpeningEvalCache(depth: depth),
      shouldAbort: () => _cancelled,
    );
    final positions = <TacticsPosition>[];
    var completedGames = 0;

    listeners.onGameProgress?.call(0, 0, tasks.length);
    for (final task in tasks) {
      if (_cancelled) break;
      try {
        final outcome = await analyzer.analyze(
          gameText: task.gameText,
          username: usernameLower,
          gameId: task.gameId,
          onSiteProgress: (done, total) {
            listeners.progress?.call(
              'Analyzing game ${completedGames + 1}/${tasks.length} '
              '(move $done/$total, ${positions.length} tactics found)...',
            );
            listeners.onGameProgress?.call(
              (completedGames + done / total) / tasks.length,
              completedGames,
              tasks.length,
            );
          },
        );
        if (_cancelled) break;
        if (outcome == null) continue;
        positions.addAll(outcome.positions);
        await _commitOutcome(task.gameId, outcome, listeners);
      } catch (e) {
        if (_cancelled) break;
        if (_database.lastWriteError != null) rethrow;
        if (kDebugMode) log.e('Error analyzing game ${task.gameId}: $e');
      }

      completedGames++;
      listeners.progress?.call(
        'Analyzed $completedGames/${tasks.length} games '
        '(${positions.length} tactics found)...',
      );
      listeners.onGameProgress?.call(
        completedGames / tasks.length,
        completedGames,
        tasks.length,
      );
    }

    // On cancel the UI clears itself — no message needed.
    if (!_cancelled) {
      listeners.progress?.call(
        'Done! Analyzed ${tasks.length} games'
        '${selection.skipped > 0 ? ', skipped ${selection.skipped}' : ''}. '
        'Found ${positions.length} tactics positions.',
      );
    }
    return (
      positions: positions,
      // What this run got through, not what it set out to do: the loop
      // breaks on cancel, and a game whose analysis threw is not reviewed
      // either. [resumeStoredPgns] sums these across two batches, and the
      // caller uses the total to decide whether anything was looked at.
      gamesAnalyzed: completedGames,
      gamesSkipped: selection.skipped,
    );
  }

  /// Persist one reviewed game and tell the listeners about it.
  ///
  /// Only a non-null outcome reaches here on purpose. [TacticsGameAnalyzer]
  /// returns null when neither PGN header matches the username — the game is
  /// not mine — and when the run was cancelled partway. Marking either
  /// analyzed is permanent and only `clearAnalyzedGames` undoes it, so one
  /// import run under a typo'd or since-changed username used to write off
  /// the whole library: correcting the username afterwards never looked at
  /// those games again. A game that *is* mine but yielded no puzzle still
  /// returns an outcome (with empty positions), so "reviewed, nothing wrong"
  /// is still recorded and is never analyzed twice.
  Future<void> _commitOutcome(
    String gameId,
    GameMineOutcome outcome,
    _RunListeners listeners,
  ) async {
    await _database.commitAnalyzedGame(gameId, outcome.positions);

    // Puzzles and completion markers are already durable. A mid-analysis
    // app close doesn't permanently skip this game.
    final onPositionFound = listeners.onPositionFound;
    if (onPositionFound != null) {
      for (final position in outcome.positions) {
        await onPositionFound(position);
      }
    }
    // The same pass that found the puzzles also knows how messy the game
    // was; report it so the games list never needs a second engine pass.
    listeners.onGameReviewed?.call(
      outcome.dedupKey,
      ReviewCounts(
        inaccuracies: outcome.inaccuracies,
        mistakes: outcome.mistakes,
        blunders: outcome.blunders,
      ),
    );
    // The same pass scored every position on the way to those counts; hand
    // the series over so the games cache can carry it.
    final annotated = outcome.annotatedMovetext;
    if (annotated != null) {
      listeners.onGameAnnotated?.call(outcome.dedupKey, annotated);
    }
    await _database.markGameAnalyzed(gameId);
  }
}
