/// Orchestrates Lichess / Chess.com tactics imports against [TacticsDatabase].
library;

import 'package:flutter/foundation.dart';

import '../../models/tactics_position.dart';
import '../../utils/app_messages.dart';
import '../../utils/log.dart';
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

class TacticsImportCoordinator extends ChangeNotifier {
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

  /// Recompute [pendingGameCount] from stored PGNs vs analyzed game IDs.
  /// Only counts games for platforms with a configured username, since
  /// resume cannot process games without one.
  Future<void> refreshPendingCount({
    String? lichessUsername,
    String? chesscomUsername,
  }) async {
    final service = TacticsImportService(database: database);
    await service.initialize();
    final counts = await service.countPendingGames(
      lichessUsername: lichessUsername,
      chesscomUsername: chesscomUsername,
    );
    pendingGameCount = counts.pending;
    totalStoredGames = counts.total;
    notifyListeners();
  }

  /// Resume analysis of stored PGN games that weren't analyzed yet.
  Future<void> resumeAnalysis({
    required String? lichessUsername,
    required String? chesscomUsername,
    required int depth,
    required int cores,
  }) async {
    if (isImporting) return;

    final importService =
        activeImport = TacticsImportService(database: database);

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
        maxCores: cores,
        progressCallback: _onProgress,
        onPositionFound: _onPositionFound,
      );

      await database.loadPositions();
      importStatus = _statusMessage(result);
      notifyListeners();
    } finally {
      activeImport = null;
      isImporting = false;
      await refreshPendingCount(
        lichessUsername: lichessUsername,
        chesscomUsername: chesscomUsername,
      );
    }
  }

  /// Runs an import to completion. Returns `true` when a result was produced,
  /// `false` when it was skipped because another import is already running.
  /// Throws [TacticsImportUsernameRequired] for an empty username; other
  /// failures propagate to the caller.
  Future<bool> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
  }) async {
    if (isImporting) return false;
    if (params.username.isEmpty) {
      throw const TacticsImportUsernameRequired();
    }

    final importService =
        activeImport = TacticsImportService(database: database);
    final depth = params.depth.clamp(1, 25);
    final cores = params.cores.clamp(1, TacticsImportService.availableCores);

    importStatus = 'Initializing...';
    isImporting = true;
    newPositionsFound = 0;
    notifyListeners();

    try {
      await importService.initialize();

      final since =
          params.mode == TacticsImportMode.sinceDate ? params.since : null;

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

      await database.loadPositions();
      importStatus = _statusMessage(result);
      notifyListeners();
      return true;
    } finally {
      activeImport = null;
      isImporting = false;
      await refreshPendingCount(
        lichessUsername:
            source == TacticsImportSource.lichess ? params.username : null,
        chesscomUsername:
            source == TacticsImportSource.chessCom ? params.username : null,
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
            since: since ?? DateTime.now().subtract(const Duration(days: 7)),
            depth: depth,
            cores: cores,
          ),
        );
        if (imported) {
          onFetched?.call(source, DateTime.now());
        }
      } catch (e) {
        log.w('Auto-fetch ${source.name} failed: $e',
            name: 'TacticsImportCoordinator');
        dismissImportStatus();
      }
    }

    await fetchOne(
        TacticsImportSource.lichess, lichessUsername, lichessLastFetch);
    await fetchOne(
        TacticsImportSource.chessCom, chesscomUsername, chesscomLastFetch);
  }

  void cancelImport() {
    activeImport?.cancel();
    importStatus = null;
    isImporting = false;
    notifyListeners();
  }

  void dismissImportStatus() {
    importStatus = null;
    notifyListeners();
  }

  void _onProgress(String message) {
    importStatus = message;
    notifyListeners();
  }

  Future<void> _onPositionFound(TacticsPosition position) async {
    await database.addPosition(position);
    newPositionsFound++;
    notifyListeners();
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
