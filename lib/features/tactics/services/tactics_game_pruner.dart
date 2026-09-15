/// Storage hygiene for the tactics game store: drops stored source games
/// that no longer serve the resume queue.
library;

import 'package:flutter/foundation.dart';

import '../../../services/game_store/game_store.dart';
import '../../../services/game_store/game_store_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../utils/log.dart';
import 'tactics_import_pgn_helpers.dart';

class TacticsGamePruner {
  const TacticsGamePruner();

  /// Remove stored PGNs that no longer serve the resume queue: games
  /// [isAnalyzed] reports as done, and games played before [since]
  /// (expired). Games a saved tactic references are always kept — the
  /// tactics PGN tab shows them as the full source game. Returns how many
  /// games were removed.
  ///
  /// The analyzed-IDs list is intentionally left alone — it's a few bytes
  /// per game and is what prevents re-analysis when an overlapping date
  /// range is fetched again later.
  Future<int> prune({
    required bool Function(String gameId) isAnalyzed,
    DateTime? since,
  }) async {
    final store = await GameStoreService.instance.open();
    final games = store.summaries(GameCollections.tactics);
    if (games.isEmpty) return 0;

    final referenced = await _tacticReferencedGameIds();
    final remove = <String>[];
    for (final summary in games) {
      final game = summary.headerBlock;
      final gameId = extractGameId(game);
      if (gameId.isNotEmpty && referenced.contains(gameId)) continue;
      if (gameId.isNotEmpty && isAnalyzed(gameId)) {
        remove.add(summary.key);
        continue;
      }
      if (since != null && isGameBefore(game, since)) remove.add(summary.key);
    }
    if (remove.isEmpty) return 0;

    final removed = store.deleteKeys(GameCollections.tactics, remove);
    if (kDebugMode) {
      log.i('Pruned $removed stored PGNs (${games.length - removed} kept)');
    }
    return removed;
  }

  /// GameIds referenced by a saved tactic in any tactics set or study on
  /// disk. The stored-PGN archive doubles as the source-game store for the
  /// tactics PGN tab (full game fast-forwarded to the tactic), so these
  /// games must survive pruning even after analysis.
  Future<Set<String>> _tacticReferencedGameIds() async {
    final ids = <String>{};
    final storage = StorageFactory.instance;
    final gameIdRe = RegExp(r'\[GameId "([^"]+)"\]');
    for (final path in [
      for (final set in await storage.listTacticsSets()) set.filePath,
      for (final study in await storage.listStudyFiles()) study.filePath,
    ]) {
      final content = await storage.readFile(path);
      if (content == null) {
        throw StateError('Tactics reference file disappeared: $path');
      }
      for (final match in gameIdRe.allMatches(content)) {
        ids.add(match.group(1)!);
      }
    }
    return ids;
  }
}
