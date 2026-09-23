import 'puzzle.dart';

/// The order a session plays its puzzles in.
enum PuzzleOrder {
  newest('Newest first'),
  leastReviewed('Least reviewed'),
  worstSuccess('Worst success rate'),
  random('Random');

  const PuzzleOrder(this.label);

  final String label;
}

/// Which puzzles a session plays and in what order: the old app's practice
/// queue, kept between launches. The defaults are its defaults — blunders,
/// mistakes and custom puzzles from the last fortnight of games, newest
/// first, one-star puzzles hidden.
final class PuzzleFilter {
  const PuzzleFilter({
    this.order = PuzzleOrder.newest,
    this.groupByGame = true,
    this.kinds = const {
      MistakeKind.blunder,
      MistakeKind.mistake,
      MistakeKind.custom,
    },
    this.unreviewedOnly = false,
    this.hideOneStar = true,
    this.days,
  });

  final PuzzleOrder order;

  /// Puzzles from one game play one after another, in move order.
  final bool groupByGame;

  final Set<MistakeKind> kinds;
  final bool unreviewedOnly;
  final bool hideOneStar;

  /// Only games played in the last this many days, today being the first;
  /// null for every date, as a set starts: an old set opened for the first
  /// time must not look empty. Puzzles with no date always pass.
  final int? days;

  static const defaults = PuzzleFilter();

  PuzzleFilter copyWith({
    PuzzleOrder? order,
    bool? groupByGame,
    Set<MistakeKind>? kinds,
    bool? unreviewedOnly,
    bool? hideOneStar,
    int? Function()? days,
  }) => PuzzleFilter(
    order: order ?? this.order,
    groupByGame: groupByGame ?? this.groupByGame,
    kinds: kinds ?? this.kinds,
    unreviewedOnly: unreviewedOnly ?? this.unreviewedOnly,
    hideOneStar: hideOneStar ?? this.hideOneStar,
    days: days == null ? this.days : days(),
  );

  /// Whether [puzzle] is one a session plays, on [today].
  bool admits(Puzzle puzzle, DateTime today) {
    if (hideOneStar && puzzle.stats.stars == 1) return false;
    if (unreviewedOnly && !puzzle.stats.isNew) return false;
    if (!kinds.contains(puzzle.kind)) return false;
    return _recent(puzzle, today);
  }

  bool _recent(Puzzle puzzle, DateTime today) {
    final window = days;
    final played = puzzle.playedOn;
    if (window == null || played == null || puzzle.kind == MistakeKind.custom) {
      return true;
    }
    final cutoff = DateTime(today.year, today.month, today.day - (window - 1));
    return !played.isBefore(cutoff);
  }

  Map<String, Object?> toJson() => {
    'order': order.name,
    'groupByGame': groupByGame,
    'kinds': [
      for (final kind in MistakeKind.values)
        if (kinds.contains(kind)) kind.name,
    ],
    'unreviewedOnly': unreviewedOnly,
    'hideOneStar': hideOneStar,
    'days': days,
  };

  /// Reads what [toJson] wrote; anything missing or wrong keeps its default.
  factory PuzzleFilter.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return defaults;
    final kinds = json['kinds'];
    return PuzzleFilter(
      order: PuzzleOrder.values.asNameMap()[json['order']] ?? defaults.order,
      groupByGame: _bool(json['groupByGame'], defaults.groupByGame),
      kinds: kinds is List
          ? {for (final name in kinds) ?MistakeKind.values.asNameMap()[name]}
          : defaults.kinds,
      unreviewedOnly: _bool(json['unreviewedOnly'], defaults.unreviewedOnly),
      hideOneStar: _bool(json['hideOneStar'], defaults.hideOneStar),
      // A null that was written means every date; one that was not is a
      // file from before the window was kept, which gets the default.
      days: switch (json['days']) {
        final int days when days > 0 => days,
        null when json.containsKey('days') => null,
        _ => defaults.days,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PuzzleFilter &&
      other.order == order &&
      other.groupByGame == groupByGame &&
      other.kinds.length == kinds.length &&
      other.kinds.containsAll(kinds) &&
      other.unreviewedOnly == unreviewedOnly &&
      other.hideOneStar == hideOneStar &&
      other.days == days;

  @override
  int get hashCode => Object.hash(
    order,
    groupByGame,
    Object.hashAllUnordered(kinds),
    unreviewedOnly,
    hideOneStar,
    days,
  );
}

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

/// The puzzles [filter] admits on [today], in the order a session plays
/// them.
///
/// Newest compares the games' PGN dates as text, which for `YYYY.MM.DD` is
/// the same as comparing days, and keeps file order among one day's games.
/// A part of the date the game does not know, `??`, counts as the lowest:
/// `2026.09.??` comes after every known day of that month and `????.??.??`
/// after every date.
///
/// Random ranks each puzzle by a hash of [seed] and its position, so one
/// seed keeps one order however often the puzzles' headers are written;
/// another seed is another shuffle.
///
/// Grouping by game then ranks each game by where its first puzzle came and
/// plays that game's puzzles together, earliest move first — so a game's
/// three mistakes are three puzzles in a row, in the order they were made.
List<Puzzle> queueOf(
  List<Puzzle> puzzles,
  PuzzleFilter filter, {
  required DateTime today,
  int seed = 0,
}) {
  final chosen = [
    for (final puzzle in puzzles)
      if (filter.admits(puzzle, today)) puzzle,
  ];
  switch (filter.order) {
    case PuzzleOrder.newest:
      _stableSort(chosen, (a, b) => _day(b).compareTo(_day(a)));
    case PuzzleOrder.leastReviewed:
      _stableSort(chosen, (a, b) => a.stats.reviews.compareTo(b.stats.reviews));
    case PuzzleOrder.worstSuccess:
      _stableSort(
        chosen,
        (a, b) => a.stats.successRate.compareTo(b.stats.successRate),
      );
    case PuzzleOrder.random:
      _stableSort(
        chosen,
        (a, b) => Object.hash(seed, a.fen).compareTo(Object.hash(seed, b.fen)),
      );
  }
  return filter.groupByGame ? _grouped(chosen) : chosen;
}

/// A puzzle's date as text that sorts, an unknown part as zeros.
String _day(Puzzle puzzle) => puzzle.date.replaceAll('?', '0');

List<Puzzle> _grouped(List<Puzzle> ordered) {
  final rank = <String, int>{};
  for (final puzzle in ordered) {
    rank.putIfAbsent(_gameOf(puzzle), () => rank.length);
  }
  final grouped = [...ordered];
  _stableSort(grouped, (a, b) {
    final byGame = rank[_gameOf(a)]!.compareTo(rank[_gameOf(b)]!);
    return byGame != 0 ? byGame : a.moveNumber.compareTo(b.moveNumber);
  });
  return grouped;
}

/// Which game a puzzle came from. A puzzle with no game of its own is a
/// group of one.
String _gameOf(Puzzle puzzle) => puzzle.played == null
    ? '#${puzzle.index}'
    : '${puzzle.white}|${puzzle.black}|${puzzle.date}|${puzzle.gameId}';

/// [List.sort] is not stable; ties keep the order they came in here.
void _stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = [for (final (i, item) in list.indexed) (i, item)];
  indexed.sort((a, b) {
    final order = compare(a.$2, b.$2);
    return order != 0 ? order : a.$1.compareTo(b.$1);
  });
  for (final (at, (_, item)) in indexed.indexed) {
    list[at] = item;
  }
}
