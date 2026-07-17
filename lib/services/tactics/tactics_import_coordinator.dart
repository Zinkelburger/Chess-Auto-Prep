/// Orchestrates Lichess / Chess.com tactics imports against [TacticsDatabase].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/tactics_position.dart';
import '../../utils/app_messages.dart';
import '../../utils/log.dart';
import '../../utils/safe_change_notifier.dart';
import '../tactics_database.dart';
import '../tactics_import_service.dart' show ImportResult, TacticsImportService;

enum TacticsImportSource { lichess, chessCom }

enum TacticsImportMode { recent, sinceDate }

class TacticsImportParams {
  const TacticsImportParams({
    required this.username,
    this.mode = TacticsImportMode.recent,
    this.maxGames = 20,
    this.since,
    this.depth = 15,
    this.cores = 1,
  });

  final String username;
  final TacticsImportMode mode;
  final int maxGames;
  final DateTime? since;
  final int depth;
  final int cores;
}

class TacticsImportCoordinator extends ChangeNotifier with SafeChangeNotifier {
  TacticsImportCoordinator({TacticsDatabase? database})
    : database = database ?? TacticsDatabase();

  final TacticsDatabase database;

  String? importStatus;
  bool isImporting = false;
  int newPositionsFound = 0;
  TacticsImportService? activeImport;

  /// Number of stored PGN games not yet analyzed (0 when up-to-date).
  int pendingGameCount = 0;

  /// Total number of PGN games in storage.
  int totalStoredGames = 0;

  /// Last-known usernames, remembered so internal refreshes after an
  /// import (which only knows its own source's username) still count
  /// pending games for both platforms.
  String? _lichessUsername;
  String? _chesscomUsername;

  /// Streamed finds are buffered and committed in batches — committing per
  /// position re-encodes and rewrites the whole set file each time, which
  /// starved the UI thread for the entire import.
  final List<TacticsPosition> _foundBuffer = [];
  Timer? _foundFlushTimer;
  static const _foundFlushInterval = Duration(seconds: 2);

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

  /// Commit buffered finds to the database: one notify + one file write per
  /// batch. Must run before any [TacticsDatabase.loadPositions] (which
  /// reloads from disk) or the buffered finds would be dropped.
  Future<void> _flushFoundPositions() async {
    _foundFlushTimer?.cancel();
    _foundFlushTimer = null;
    if (_foundBuffer.isEmpty) return;
    final batch = List<TacticsPosition>.of(_foundBuffer);
    _foundBuffer.clear();
    await database.addPositions(batch);
  }

  @override
  void dispose() {
    _notifyThrottle?.cancel();
    _foundFlushTimer?.cancel();
    // Mid-import: leave the buffer for the import try/finally flush so we
    // don't race a double-write. Orphaned finds (no active import) are
    // persisted before super.dispose while [database] is still owned.
    if (!isImporting && _foundBuffer.isNotEmpty) {
      final batch = List<TacticsPosition>.of(_foundBuffer);
      _foundBuffer.clear();
      unawaited(database.addPositions(batch));
    }
    super.dispose();
  }

  /// Start of the pending/resume recency window, evaluated fresh on every
  /// count. Set by the UI from the fetch-window form; games played before
  /// it are treated as expired (not pending, not resumed). Null = no window.
  DateTime? Function()? pendingSinceProvider;

  /// Recompute [pendingGameCount] from stored PGNs vs analyzed game IDs.
  /// Only counts games for platforms with a configured username, since
  /// resume cannot process games without one. A null username keeps the
  /// previously remembered value.
  ///
  /// Also storage hygiene: analyzed and expired games no longer serve the
  /// resume queue, so they are pruned from the stored-PGN file here —
  /// except mid-import, when the running import appends to that same file.
  Future<void> refreshPendingCount({
    String? lichessUsername,
    String? chesscomUsername,
  }) async {
    if (lichessUsername != null) _lichessUsername = lichessUsername;
    if (chesscomUsername != null) _chesscomUsername = chesscomUsername;
    final service = TacticsImportService(database: database);
    await service.initialize();
    final since = pendingSinceProvider?.call();
    if (!isImporting) {
      await service.pruneStoredPgns(since: since);
    }
    final counts = await service.countPendingGames(
      lichessUsername: _lichessUsername,
      chesscomUsername: _chesscomUsername,
      since: since,
    );
    pendingGameCount = counts.pending;
    totalStoredGames = counts.total;
    notifyListeners();
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
      );

      await _flushFoundPositions();
      await database.loadPositions();
      // Cancelled: clear the "Stopping…" note instead of claiming success.
      importStatus = importService.wasCancelled ? null : _statusMessage(result);
      notifyListeners();
    } finally {
      // On an abnormal exit the try block never flushed — persist what the
      // cancelled/failed run found so far.
      await _flushFoundPositions();
      activeImport = null;
      isImporting = false;
      await refreshPendingCount(
        lichessUsername: lichessUsername,
        chesscomUsername: chesscomUsername,
      );
    }
  }

  /// Runs an import to completion. Returns `true` when it ran to the end,
  /// `false` when it was skipped (another import already running) or
  /// cancelled partway. Throws [TacticsImportUsernameRequired] for an empty
  /// username; other failures propagate to the caller.
  Future<bool> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
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
    notifyListeners();

    try {
      await importService.initialize();

      final since = params.mode == TacticsImportMode.sinceDate
          ? params.since
          : null;

      final ImportResult result;
      if (source == TacticsImportSource.lichess) {
        result = await importService.importGamesFromLichess(
          params.username,
          maxGames: params.maxGames,
          since: since,
          depth: depth,
          maxCores: cores,
          progressCallback: _onProgress,
          onPositionFound: _onPositionFound,
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
        );
      }

      await _flushFoundPositions();
      await database.loadPositions();
      // A cancelled run must not look like a completed one: no success
      // banner, and `false` so callers (auto-fetch, manual import) don't
      // advance their last-fetch timestamp past unanalyzed games.
      if (importService.wasCancelled) {
        importStatus = null;
        notifyListeners();
        return false;
      }
      importStatus = _statusMessage(result);
      notifyListeners();
      return true;
    } finally {
      // On an abnormal exit the try block never flushed — persist what the
      // cancelled/failed run found so far.
      await _flushFoundPositions();
      activeImport = null;
      isImporting = false;
      await refreshPendingCount(
        lichessUsername: source == TacticsImportSource.lichess
            ? params.username
            : null,
        chesscomUsername: source == TacticsImportSource.chessCom
            ? params.username
            : null,
      );
    }
  }

  /// Fetch new games since the last fetch for every configured platform.
  /// Used by startup auto-fetch. Failures are logged and dismissed; a
  /// successful fetch reports its timestamp through [onFetched] so the
  /// caller can persist it.
  Future<void> autoFetch({
    String? lichessUsername,
    String? chesscomUsername,
    DateTime? lichessLastFetch,
    DateTime? chesscomLastFetch,
    required int depth,
    required int cores,
    void Function(TacticsImportSource source, DateTime fetchedAt)? onFetched,
  }) async {
    Future<void> fetchOne(
      TacticsImportSource source,
      String? username,
      DateTime? since,
    ) async {
      if (username == null || username.isEmpty) return;
      try {
        final imported = await import(
          source: source,
          params: TacticsImportParams(
            username: username,
            mode: TacticsImportMode.sinceDate,
            since: since ?? DateTime.now().subtract(const Duration(days: 14)),
            depth: depth,
            cores: cores,
          ),
        );
        if (imported) {
          onFetched?.call(source, DateTime.now());
        }
      } catch (e) {
        log.w(
          'Auto-fetch ${source.name} failed: $e',
          name: 'TacticsImportCoordinator',
        );
        dismissImportStatus();
      }
    }

    await fetchOne(
      TacticsImportSource.lichess,
      lichessUsername,
      lichessLastFetch,
    );
    await fetchOne(
      TacticsImportSource.chessCom,
      chesscomUsername,
      chesscomLastFetch,
    );
  }

  /// Ask the running import to stop. `isImporting` stays true until the run
  /// actually winds down (its finally block clears it) — flipping it here
  /// would let a second import start while the first still holds the engine
  /// pool.
  void cancelImport() {
    if (activeImport == null) return;
    activeImport?.cancel();
    importStatus = 'Stopping…';
    notifyListeners();
  }

  void dismissImportStatus() {
    importStatus = null;
    notifyListeners();
  }

  void _onProgress(String message) {
    importStatus = message;
    _notifyThrottled();
  }

  Future<void> _onPositionFound(TacticsPosition position) async {
    _foundBuffer.add(position);
    newPositionsFound++;
    _foundFlushTimer ??= Timer(_foundFlushInterval, () {
      _foundFlushTimer = null;
      unawaited(_flushFoundPositions());
    });
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
