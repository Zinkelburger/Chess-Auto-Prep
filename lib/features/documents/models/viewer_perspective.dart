import '../../../models/pgn_game_entry.dart';
import '../../../chess_core/pgn/pgn_collection_players.dart';

/// Board perspective mode persisted as [StudyPerspective] header on first game.
enum PerspectiveMode { white, black, player }

class Perspective {
  final PerspectiveMode mode;

  /// Only meaningful when [mode] is [PerspectiveMode.player].
  final String playerName;

  const Perspective({this.mode = PerspectiveMode.white, this.playerName = ''});

  String toHeaderValue() => switch (mode) {
    PerspectiveMode.white => 'white',
    PerspectiveMode.black => 'black',
    PerspectiveMode.player => playerName,
  };

  static Perspective fromHeaderValue(String value) {
    final v = value.trim();
    if (v.isEmpty || v == 'white' || v == 'auto') {
      return const Perspective();
    }
    if (v == 'black') return const Perspective(mode: PerspectiveMode.black);
    return Perspective(mode: PerspectiveMode.player, playerName: v);
  }

  /// The perspective a freshly loaded collection should open in.
  ///
  /// An explicit `StudyPerspective` header wins. Failing that, a collection
  /// of two or more games that share one protagonist opens from that
  /// player's side. Otherwise the reader's [current] preference carries over:
  /// a single game has no protagonist beyond whoever is looking at it, and an
  /// explicit flip on the previous collection stays in force.
  static Perspective forCollection(
    List<PgnGameEntry> entries, {
    required Perspective current,
  }) {
    final raw = entries.isNotEmpty
        ? (entries.first.headers['StudyPerspective'] ?? '')
        : '';
    if (raw.trim().isNotEmpty) return Perspective.fromHeaderValue(raw);
    if (entries.length < 2) return current;
    final protagonist = detectProtagonistFrom(entries);
    if (protagonist == null) return current;
    return Perspective(mode: PerspectiveMode.player, playerName: protagonist);
  }

  /// Null leaves the reader's orientation unchanged when a player is absent
  /// or ambiguous. Exact names take precedence over surname fallbacks.
  bool? flippedFor(Map<String, String> headers) {
    if (mode == PerspectiveMode.white) return false;
    if (mode == PerspectiveMode.black) return true;
    String normalize(String? value) => (value ?? '').toLowerCase().trim();
    final target = normalize(playerName);
    if (target.isEmpty || target == '?') return null;
    final white = normalize(headers['White']);
    final black = normalize(headers['Black']);
    final exactWhite = white == target;
    final exactBlack = black == target;
    if (exactWhite || exactBlack) {
      return exactWhite == exactBlack ? null : exactBlack;
    }
    String surname(String value) => value.split(',').first.trim();
    final name = surname(target);
    if (name.isEmpty) return null;
    final whiteMatch = surname(white) == name;
    final blackMatch = surname(black) == name;
    return whiteMatch == blackMatch ? null : blackMatch;
  }

  @override
  bool operator ==(Object other) =>
      other is Perspective &&
      other.mode == mode &&
      other.playerName == playerName;

  @override
  int get hashCode => Object.hash(mode, playerName);
}
