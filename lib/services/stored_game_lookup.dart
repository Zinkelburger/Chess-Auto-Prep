/// Lookup of full source games in the stored-game archive by the `[GameId]`
/// header injected at import time. Used by the PGN viewer (show the whole
/// game behind a tactic) and the tactics game menu (add game to study).
library;

import 'package:flutter/foundation.dart';

import 'game_store/game_store.dart';
import 'game_store/game_store_service.dart';

/// The stored game whose `[GameId "…"]` header matches [gameId], or the
/// empty string when the archive doesn't have it (external sets, custom
/// puzzles, games pruned before tactic references were kept).
///
/// One indexed lookup in the games database — the archive used to be a
/// flat file split in full for every call.
Future<String> findStoredGamePgn(String gameId) async {
  try {
    final store = await GameStoreService.instance.open();
    return store.byKey(GameCollections.tactics, gameId)?.pgn ?? '';
  } catch (e) {
    debugPrint('Error finding game PGN: $e');
  }
  return '';
}
