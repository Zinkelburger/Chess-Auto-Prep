import 'dart:convert';

import '../../../models/pgn_filter_models.dart';
import '../../../models/pgn_game_entry.dart';
import 'package:chess_auto_prep/chess_core/pgn/game_identity.dart';

/// Per-file reading position, separate from the PGN's chess annotations.
class ViewerSession {
  const ViewerSession({
    required this.gameIndex,
    required this.gameKey,
    required this.ply,
    required this.sortMode,
  });

  final int gameIndex;
  final String gameKey;
  final int ply;
  final GameSortMode sortMode;

  static String keyFor(PgnGameEntry game) =>
      canonicalGameKey(game.headers, game.pgnText);

  int locate(List<PgnGameEntry> games) {
    if (gameIndex >= 0 &&
        gameIndex < games.length &&
        keyFor(games[gameIndex]) == gameKey) {
      return gameIndex;
    }
    return games.indexWhere((game) => keyFor(game) == gameKey);
  }

  String encode() => jsonEncode({
    'gameIndex': gameIndex,
    'gameKey': gameKey,
    'ply': ply,
    'sort': sortMode.name,
  });

  static ViewerSession? decode(String? value) {
    if (value == null) return null;
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      final ply = data['ply'] as int;
      return ViewerSession(
        gameIndex: data['gameIndex'] as int,
        gameKey: data['gameKey'] as String,
        ply: ply < 0 ? 0 : ply,
        sortMode: GameSortMode.values.firstWhere(
          (mode) => mode.name == data['sort'],
          orElse: () => GameSortMode.fileOrder,
        ),
      );
    } catch (_) {
      // A malformed or pre-format entry only means there is no session to
      // restore; the reader opens at the start as if none had been saved.
      return null;
    }
  }
}
