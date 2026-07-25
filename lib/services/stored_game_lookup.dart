/// Lookup of full source games in the stored-PGN archive by the `[GameId]`
/// header injected at import time. Used by the PGN viewer (show the whole
/// game behind a tactic) and the tactics game menu (add game to study).
library;

import 'package:flutter/foundation.dart';

import 'pgn_parsing_service.dart';
import 'storage/storage_factory.dart';

/// The stored game whose `[GameId "…"]` header matches [gameId], or the
/// empty string when the archive doesn't have it (external sets, custom
/// puzzles, games pruned before tactic references were kept).
Future<String> findStoredGamePgn(String gameId) async {
  try {
    final content = await StorageFactory.instance.readImportedPgns();
    if (content == null || content.isEmpty) return '';
    for (final gameText in splitPgnIntoGames(content)) {
      if (gameText.contains('[GameId "$gameId"]')) return gameText;
    }
  } catch (e) {
    debugPrint('Error finding game PGN: $e');
  }
  return '';
}
