/// Which database the explorer asks and how it is narrowed: what the top of
/// the Explorer tab sets, and what the settings file remembers.
library;

/// The databases the explorer can ask.
enum ExplorerSource {
  /// Lichess's masters database: titled players, over the board.
  masters('Masters'),

  /// Lichess's own games, narrowed by speed and rating.
  lichess('Lichess'),

  /// The master games on this machine, the TWIC import; works offline.
  twic('TWIC'),

  /// The games of the file open in the workspace: the old viewer's `Tree`.
  thisFile('This file'),

  /// The user's own saved games.
  myGames('My games');

  const ExplorerSource(this.title);

  final String title;

  /// Built from games on this machine and answered from memory: nothing
  /// to wait for between positions, and nothing to keep between sessions.
  bool get local => this == thisFile || this == myGames;
}

/// The time controls the Lichess database is split by, as the API names
/// them.
enum LichessSpeed { bullet, blitz, rapid, classical, correspondence }

/// The rating bands the Lichess database offers.
const lichessRatings = [1600, 1800, 2000, 2200, 2500];

/// One choice of database and its narrowing, as a value.
final class ExplorerChoice {
  const ExplorerChoice({
    this.source = ExplorerSource.masters,
    this.speeds = defaultSpeeds,
    this.ratings = defaultRatings,
    this.classicalOnly = false,
  });

  static const defaults = ExplorerChoice();
  static const defaultSpeeds = {
    LichessSpeed.blitz,
    LichessSpeed.rapid,
    LichessSpeed.classical,
  };
  static const defaultRatings = {2000, 2200, 2500};

  final ExplorerSource source;

  /// The Lichess speeds asked for; ignored by the other sources.
  final Set<LichessSpeed> speeds;

  /// The Lichess rating bands asked for; ignored by the other sources.
  final Set<int> ratings;

  /// TWIC only: count classical over-the-board games and nothing else.
  final bool classicalOnly;

  ExplorerChoice copyWith({
    ExplorerSource? source,
    Set<LichessSpeed>? speeds,
    Set<int>? ratings,
    bool? classicalOnly,
  }) => ExplorerChoice(
    source: source ?? this.source,
    speeds: speeds ?? this.speeds,
    ratings: ratings ?? this.ratings,
    classicalOnly: classicalOnly ?? this.classicalOnly,
  );

  /// The speeds in the API's order, bullet first.
  List<LichessSpeed> get speedsInOrder => [
    for (final speed in LichessSpeed.values)
      if (speeds.contains(speed)) speed,
  ];

  List<int> get ratingsInOrder => [
    for (final rating in lichessRatings)
      if (ratings.contains(rating)) rating,
  ];

  /// How the chosen database is narrowed, in a few words:
  /// `blitz rapid classical · 2000+`, `classical only`, or empty when it is
  /// not narrowed at all. The database itself is the pressed button.
  String get narrowing => switch (source) {
    ExplorerSource.masters ||
    ExplorerSource.thisFile ||
    ExplorerSource.myGames => '',
    ExplorerSource.twic => classicalOnly ? 'classical only' : '',
    ExplorerSource.lichess =>
      '${speedsInOrder.map((s) => s.name).join(' ')} · ${_ratingsSummary()}',
  };

  /// `2000+` when the bands run to the top without a hole, else the bands.
  String _ratingsSummary() {
    final chosen = ratingsInOrder;
    if (chosen.isEmpty) return 'any rating';
    final from = lichessRatings.indexOf(chosen.first);
    final toTheTop = lichessRatings.sublist(from);
    if (chosen.length == toTheTop.length) return '${chosen.first}+';
    return chosen.join(' ');
  }

  /// What a cache is keyed by: everything that changes the answer.
  String get key =>
      '${source.name}|${speedsInOrder.map((s) => s.name).join(',')}|'
      '${ratingsInOrder.join(',')}|$classicalOnly';

  Map<String, Object> toJson() => {
    'source': source.name,
    'speeds': [for (final speed in speedsInOrder) speed.name],
    'ratings': ratingsInOrder,
    'classicalOnly': classicalOnly,
  };

  /// A choice read back from the settings file; anything missing or
  /// unknown falls back to the default for that part.
  factory ExplorerChoice.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return defaults;
    final source = ExplorerSource.values
        .where((s) => s.name == json['source'])
        .firstOrNull;
    final speeds = json['speeds'];
    final ratings = json['ratings'];
    final classical = json['classicalOnly'];
    return ExplorerChoice(
      source: source ?? defaults.source,
      speeds: speeds is List
          ? {
              for (final name in speeds)
                for (final speed in LichessSpeed.values)
                  if (speed.name == name) speed,
            }
          : defaults.speeds,
      ratings: ratings is List
          ? {
              for (final rating in ratings)
                if (rating is int && lichessRatings.contains(rating)) rating,
            }
          : defaults.ratings,
      classicalOnly: classical is bool ? classical : defaults.classicalOnly,
    );
  }

  @override
  bool operator ==(Object other) => other is ExplorerChoice && other.key == key;

  @override
  int get hashCode => key.hashCode;
}
