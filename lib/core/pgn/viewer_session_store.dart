import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/pgn_filter_models.dart';
import '../../models/pgn_game_entry.dart';
import '../../services/game_identity.dart';

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
      return null;
    }
  }
}

class ViewerSessionStore {
  static const lastFileKey = 'pgn_viewer.last_file';
  static const _prefix = 'pgn_viewer.session:';
  Future<void> _writes = Future.value();

  Future<String?> lastFile() async =>
      (await SharedPreferences.getInstance()).getString(lastFileKey);

  Future<ViewerSession?> load(String path) async {
    await _writes;
    final prefs = await SharedPreferences.getInstance();
    return ViewerSession.decode(prefs.getString('$_prefix$path'));
  }

  Future<void> save(String path, ViewerSession session) {
    final json = session.encode();
    return _writes = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix$path', json);
      await prefs.setString(lastFileKey, path);
    });
  }

  Future<void> close() => _writes = _writes.then((_) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(lastFileKey);
  });

  Future<void> flush() => _writes;
}
