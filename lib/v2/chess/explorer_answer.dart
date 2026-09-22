/// What a database says about one position: the moves played from it with
/// their results, and some games worth opening. Lichess, the masters
/// database and the local TWIC book all answer in this shape, so the tab
/// that shows it knows nothing about where it came from.
library;

/// One move played from the position, with how the games that played it
/// ended. Counts, not shares: the share is against the whole answer.
final class ExplorerMove {
  const ExplorerMove({
    required this.uci,
    required this.san,
    required this.white,
    required this.draws,
    required this.black,
  });

  final String uci;
  final String san;
  final int white;
  final int draws;
  final int black;

  int get games => white + draws + black;
}

/// One game the database names for the position: lila's top games list.
final class ExplorerGame {
  const ExplorerGame({
    required this.id,
    required this.white,
    required this.black,
    required this.result,
    this.whiteElo,
    this.blackElo,
    this.year,
    this.event = '',
  });

  /// What the database fetches the game by: a Lichess id, or the local
  /// database's row number as text.
  final String id;

  final String white;
  final String black;
  final int? whiteElo;
  final int? blackElo;

  /// `1-0`, `0-1`, `1/2-1/2` or `*`.
  final String result;

  final int? year;

  /// The event, when the database knows it; empty for Lichess games.
  final String event;
}

/// The database's answer for one position.
final class ExplorerAnswer {
  const ExplorerAnswer({
    required this.moves,
    this.games = const [],
    this.white,
    this.draws,
    this.black,
  });

  static const empty = ExplorerAnswer(moves: []);

  /// Most played first.
  final List<ExplorerMove> moves;

  /// Games at this position worth opening, strongest or newest first.
  final List<ExplorerGame> games;

  /// The result split over every game at the position, when the database
  /// reports it apart from the moves; otherwise the moves are summed.
  final int? white;
  final int? draws;
  final int? black;

  int get whiteTotal => white ?? moves.fold(0, (n, m) => n + m.white);
  int get drawTotal => draws ?? moves.fold(0, (n, m) => n + m.draws);
  int get blackTotal => black ?? moves.fold(0, (n, m) => n + m.black);

  /// How many games the position has, as the moves count them: what each
  /// move's share is measured against.
  int get total => moves.fold(0, (n, m) => n + m.games);

  bool get isEmpty => moves.isEmpty;
}

/// `812`, `1.2k`, `1.2M`: a game count in the room a gutter has.
String formatGameCount(int games) {
  if (games < 1000) return '$games';
  if (games < 1000000) return '${_short(games / 1000)}k';
  return '${_short(games / 1000000)}M';
}

String _short(double n) {
  final text = n >= 10 ? n.round().toString() : n.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// `31%`, or `<1%` under half a percent.
String formatShare(int part, int whole) {
  if (whole <= 0) return '0%';
  final share = part / whole;
  if (share < 0.005) return '<1%';
  return '${(share * 100).round()}%';
}
