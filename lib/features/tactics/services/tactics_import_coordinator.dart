/// Orchestrates Lichess / Chess.com tactics imports against [TacticsDatabase].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../games/services/games_window.dart';
import '../models/tactics_position.dart';
import '../../../utils/app_messages.dart';
import '../../../utils/log.dart';
import '../../../utils/safe_change_notifier.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/games_library/game_review_store.dart';
import '../../../services/jobs/repertoire_job.dart';
import 'tactics_database.dart';
import 'tactics_import_service.dart'
    show GameAnnotatedCallback, ImportResult, TacticsImportService;

enum TacticsImportSource { lichess, chessCom }

enum TacticsImportMode { recent, sinceDate }

class TacticsImportParams {
  const TacticsImportParams({
    required this.username,
    this.mode = TacticsImportMode.recent,
    this.maxGames,
    this.since,
    this.depth = 15,
    this.cores = 1,
  });

  final String username;
  final TacticsImportMode mode;

  /// Hard game-count limit, or `null` for "no limit" — used by sinceDate
  /// mode, where the day window is the only limit the user asked for.
  final int? maxGames;
  final DateTime? since;
  final int depth;
  final int cores;
}

class TacticsImportCoordinator extends ChangeNotifier with SafeChangeNotifier {
  TacticsImportCoordinator({
    TacticsDatabase? database,
    GamesWindowSettings? windowSettings,
  }) : database = database ?? TacticsDatabase(),
       _windowSettings = windowSettings ?? GamesWindowSettings.instance;

  final TacticsDatabase database;

  /// The app-wide "which of my games are we talking about" window — the same
  /// one the recent-games list and the review strip run on. Read directly
  /// rather than pushed in by the panel, so pruning cannot drift from the
  /// window the user can see.
  final GamesWindowSettings _windowSettings;

  String? importStatus;
  bool isImporting = false;

  /// The run's entry in the app-wide [JobManager], so every screen can see
  /// the import and cancel it. Null when no run is active.
  RepertoireJob? _job;

  /// Last progress pushed to [_job]. Message and fraction arrive through
  /// separate callbacks; compose onto this so one never resets the other.
  JobProgress _jobProgress = JobProgress.zero;

  void _updateJob({String? message, double? fraction, int? done, int? total}) {
    final job = _job;
    if (job == null) return;
    _jobProgress = JobProgress(
      fraction: fraction ?? _jobProgress.fraction,
      message: message ?? _jobProgress.message,
      nodesProcessed: done ?? _jobProgress.nodesProcessed,
      totalNodes: total ?? _jobProgress.totalNodes,
    );
    job.updateProgress(_jobProgress);
  }

  /// How far the running pass has got, for the review strip's progress bar.
  /// Zero when nothing is running.
  double get progressFraction => _jobProgress.fraction;

  /// Games finished / games this pass set out to review. Both zero before the
  /// first game report arrives.
  int get gamesDone => _jobProgress.nodesProcessed;
  int get gamesTotal => _jobProgress.totalNodes;

  /// Games whose mistake counts this coordinator has filed (see
  /// [GameReviewStore]) since the current run started.
  int gamesReviewed = 0;

  /// File one game's verdict. The store is app-wide and notifies, so the games
  /// list picks the counts up without this coordinator knowing it exists.
  void _recordReview(String dedupKey, ReviewCounts counts) {
    gamesReviewed++;
    unawaited(GameReviewStore.instance.record(dedupKey, counts));
  }

  /// Notified with one game's `[%eval]`-annotated movetext as each game
  /// finishes, keyed by its games-library identity.
  ///
  /// A hook rather than a write, because the scores belong in the games cache
  /// and this coordinator has no business knowing where that file is — the
  /// review runner owns the games list and the cache path with it. Left unset
  /// (the tactics panel's own imports), the scores are simply not stored.
  GameAnnotatedCallback? onGameAnnotated;

  void _onGameProgress(double fraction, int gamesDone, int gamesTotal) {
    // Site-level reports arrive many times per second; only forward
    // meaningful movement so the job listeners aren't rebuilt per search.
    if (gamesDone == _jobProgress.nodesProcessed &&
        gamesTotal == _jobProgress.totalNodes &&
        (fraction - _jobProgress.fraction).abs() < 0.005) {
      return;
    }
    _updateJob(fraction: fraction, done: gamesDone, total: gamesTotal);
  }

  /// True from the pause click until the run has fully wound down. Keeps the
  /// pause button single-shot and stops progress messages from overwriting
  /// the "Pausing…" status.
  bool isCancelling = false;
  int newPositionsFound = 0;
  TacticsImportService? activeImport;

  /// Progress/find notifications arrive many times per second during an
  /// import and each one repaints the whole tactics panel; coalesce them.
  Timer? _notifyThrottle;
  bool _notifyQueued = false;
  static const _notifyInterval = Duration(milliseconds: 200);

  /// Leading-edge throttle with a trailing call, so the first update paints
  /// immediately and the last one is never dropped.
  void _notifyThrottled() {
    if (_notifyThrottle != null) {
      _notifyQueued = true;
      return;
    }
    notifyListeners();
    _notifyThrottle = Timer(_notifyInterval, () {
      _notifyThrottle = null;
      if (_notifyQueued) {
        _notifyQueued = false;
        _notifyThrottled();
      }
    });
  }

  @override
  void dispose() {
    _notifyThrottle?.cancel();
    super.dispose();
  }

  /// Storage hygiene: drop stored PGNs that no longer serve the resume queue
  /// — already analyzed, or played before the shared games window — unless a
  /// saved tactic still cites them as its source game.
  ///
  /// Does nothing mid-import, when the running import is appending to that
  /// same store.
  Future<void> pruneStoredGames() async {
    if (isImporting) return;
    try {
      await _windowSettings.ensureLoaded();
      final service = TacticsImportService(database: database);
      await service.initialize();
      await service.pruneStoredPgns(
        since: _windowSettings.window.cutoffFrom(DateTime.now()),
      );
    } catch (e) {
      // This runs on screen build and after every import; the games store
      // being briefly unreachable must not throw into the widget tree.
      log.e('Could not prune stored games: $e');
    }
  }

  /// Register a starting run with the app-wide [JobManager] — so every
  /// screen can see and pause it — and lease the shared engine pool so a
  /// mode switch can't dispose the workers mid-run.
  ///
  /// The run is marked [RepertoireJob.resumable]: stopping it is a pause, not
  /// a cancel. Every game it has already reviewed keeps its counts (see
  /// [_recordReview]) and is marked analyzed, so the next run picks up at the
  /// first game it did not reach.
  void _beginJob(String label) {
    EngineLifecycle.instance.retainPool();
    _jobProgress = JobProgress.zero;
    final job = _job = JobManager.instance.createJob(
      type: JobType.tacticsImport,
      label: label,
    );
    job.resumable = true;
    job.onCancel = cancelImport;
    job.updateStatus(JobStatus.running);
  }

  /// Close out the job registered by [_beginJob]. A job already marked
  /// failed keeps that status.
  void _endJob({required bool cancelled}) {
    EngineLifecycle.instance.releasePool();
    final job = _job;
    _job = null;
    if (job == null || !job.isActive) return;
    job.updateStatus(cancelled ? JobStatus.cancelled : JobStatus.completed);
  }

  /// Resume analysis of stored PGN games that weren't analyzed yet.
  /// Games played before [since] are left alone (expired from the queue).
  Future<void> resumeAnalysis({
    required String? lichessUsername,
    required String? chesscomUsername,
    required int depth,
    required int cores,
    DateTime? since,
  }) async {
    if (isImporting) return;

    final importService = activeImport = TacticsImportService(
      database: database,
    );

    importStatus = 'Resuming analysis…';
    isImporting = true;
    newPositionsFound = 0;
    gamesReviewed = 0;
    _beginJob('Analyze stored games');
    notifyListeners();

    try {
      await importService.initialize();
      final result = await importService.resumeStoredPgns(
        lichessUsername: lichessUsername,
        chesscomUsername: chesscomUsername,
        depth: depth,
        since: since,
        maxCores: cores,
        progressCallback: _onProgress,
        onPositionFound: _onPositionFound,
        onGameProgress: _onGameProgress,
        onGameReviewed: _recordReview,
        onGameAnnotated: onGameAnnotated,
      );

      await database.loadPositions();
      // Cancelled: clear the "Pausing…" note instead of claiming success.
      importStatus = importService.wasCancelled ? null : _statusMessage(result);
    } catch (e) {
      _job?.fail('$e');
      rethrow;
    } finally {
      _endJob(cancelled: importService.wasCancelled);
      // On an abnormal exit the try block never flushed — persist what the
      // cancelled/failed run found so far.
      activeImport = null;
      isImporting = false;
      isCancelling = false;
      notifyListeners();
      await pruneStoredGames();
    }
  }

  /// Runs an import to completion. Returns `true` when it ran to the end,
  /// `false` when it was skipped (another import already running) or
  /// cancelled partway. Throws [TacticsImportUsernameRequired] for an empty
  /// username; other failures propagate to the caller.
  ///
  /// Pass [pgnContent] to review games that are already downloaded (the
  /// recent-games list's copy) instead of fetching them again — same job, same
  /// bookkeeping, one less round trip. See
  /// [TacticsImportService.reviewFetchedGames].
  ///
  /// [forceDedupKeys] names games in [pgnContent] to analyze even if they are
  /// already marked analyzed — how the caller says "these still have no
  /// mistake counts, look at them again".
  Future<bool> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
    String? pgnContent,
    Set<String> forceDedupKeys = const {},
  }) async {
    if (isImporting) return false;
    if (params.username.isEmpty) {
      throw const TacticsImportUsernameRequired();
    }

    final importService = activeImport = TacticsImportService(
      database: database,
    );
    final depth = params.depth.clamp(1, 25);
    final cores = params.cores.clamp(1, TacticsImportService.availableCores);

    importStatus = 'Initializing...';
    isImporting = true;
    newPositionsFound = 0;
    gamesReviewed = 0;
    _beginJob('Review games — ${params.username}');
    notifyListeners();

    try {
      await importService.initialize();

      final since = params.mode == TacticsImportMode.sinceDate
          ? params.since
          : null;

      final ImportResult result;
      if (pgnContent != null && pgnContent.trim().isNotEmpty) {
        result = await importService.reviewFetchedGames(
          pgnContent: pgnContent,
          username: params.username,
          depth: depth,
          maxCores: cores,
          mapChessComEloForMaia: source == TacticsImportSource.chessCom,
          forceDedupKeys: forceDedupKeys,
          progressCallback: _onProgress,
          onPositionFound: _onPositionFound,
          onGameProgress: _onGameProgress,
          onGameReviewed: _recordReview,
          onGameAnnotated: onGameAnnotated,
        );
      } else if (source == TacticsImportSource.lichess) {
        result = await importService.importGamesFromLichess(
          params.username,
          maxGames: params.maxGames,
          since: since,
          depth: depth,
          maxCores: cores,
          progressCallback: _onProgress,
          onPositionFound: _onPositionFound,
          onGameProgress: _onGameProgress,
          onGameReviewed: _recordReview,
          onGameAnnotated: onGameAnnotated,
        );
      } else {
        result = await importService.importGamesFromChessCom(
          params.username,
          maxGames: params.maxGames,
          since: since,
          depth: depth,
          maxCores: cores,
          progressCallback: _onProgress,
          onPositionFound: _onPositionFound,
          onGameProgress: _onGameProgress,
          onGameReviewed: _recordReview,
          onGameAnnotated: onGameAnnotated,
        );
      }

      await database.loadPositions();
      // A cancelled run must not look like a completed one: no success
      // banner, and `false` so callers (auto-fetch, manual import) don't
      // advance their last-fetch timestamp past unanalyzed games.
      if (importService.wasCancelled) {
        importStatus = null;
        return false;
      }
      importStatus = _statusMessage(result);
      return true;
    } catch (e) {
      _job?.fail('$e');
      rethrow;
    } finally {
      _endJob(cancelled: importService.wasCancelled);
      // On an abnormal exit the try block never flushed — persist what the
      // cancelled/failed run found so far.
      activeImport = null;
      isImporting = false;
      isCancelling = false;
      notifyListeners();
      await pruneStoredGames();
    }
  }

  /// Ask the running import to stop. `isImporting` stays true until the run
  /// actually winds down (its finally block clears it) — flipping it here
  /// would let a second import start while the first still holds the engine
  /// pool. Idempotent: repeat clicks while winding down are no-ops.
  void cancelImport() {
    if (activeImport == null || isCancelling) return;
    isCancelling = true;
    activeImport?.cancel();
    importStatus = 'Pausing…';
    _updateJob(message: 'Pausing…');
    notifyListeners();
  }

  void dismissImportStatus() {
    importStatus = null;
    notifyListeners();
  }

  void _onProgress(String message) {
    // In-flight games still report progress while winding down; don't let
    // them overwrite the "Pausing…" status.
    if (isCancelling) return;
    importStatus = message;
    _updateJob(message: message);
    _notifyThrottled();
  }

  Future<void> _onPositionFound(TacticsPosition position) async {
    // The service has committed this game before sending notifications.
    newPositionsFound++;
    _notifyThrottled();
  }

  String _statusMessage(ImportResult result) {
    if (newPositionsFound > 0) {
      return AppMessages.addedTactics(newPositionsFound);
    }
    if (result.gamesAnalyzed == 0 && result.gamesSkipped > 0) {
      return AppMessages.gamesAlreadyAnalyzed;
    }
    return AppMessages.noNewBlunders;
  }
}

/// Thrown when import is started without a username.
class TacticsImportUsernameRequired implements Exception {
  const TacticsImportUsernameRequired();
}
