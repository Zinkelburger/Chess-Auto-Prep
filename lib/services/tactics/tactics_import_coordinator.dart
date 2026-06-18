/// Orchestrates Lichess / Chess.com tactics imports against [TacticsDatabase].
library;

import 'package:flutter/foundation.dart';

import '../../models/tactics_position.dart';
import '../../utils/app_messages.dart';
import '../tactics_database.dart';
import '../tactics_import_service.dart';

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

  Future<void> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
  }) async {
    if (isImporting) return;
    if (params.username.isEmpty) {
      throw const TacticsImportUsernameRequired();
    }

    final importService = activeImport = TacticsImportService(database: database);
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

      if (source == TacticsImportSource.lichess) {
        await importService.importGamesFromLichess(
          params.username,
          maxGames: params.maxGames,
          since: since,
          depth: depth,
          maxCores: cores,
          progressCallback: _onProgress,
          onPositionFound: _onPositionFound,
        );
      } else {
        await importService.importGamesFromChessCom(
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
      importStatus = newPositionsFound == 0
          ? AppMessages.noNewBlunders
          : AppMessages.addedTactics(newPositionsFound);
      notifyListeners();
    } finally {
      activeImport = null;
      isImporting = false;
      notifyListeners();
    }
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

  void _onPositionFound(TacticsPosition position) {
    database.addPosition(position);
    newPositionsFound++;
    notifyListeners();
  }
}

/// Thrown when import is started without a username.
class TacticsImportUsernameRequired implements Exception {
  const TacticsImportUsernameRequired();
}
