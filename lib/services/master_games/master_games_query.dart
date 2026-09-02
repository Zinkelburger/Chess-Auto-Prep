/// Filters for browsing the local TWIC corpus.
///
/// The database was built to be *asked about a position* — the `book` table is
/// what the generator reads.  Browsing is the other question: which of the two
/// million stored games is worth opening.  That is a `games` scan with a WHERE
/// clause, and every column it filters on is already indexed.
///
/// The clause builder is pure so it can be tested without a database, which
/// matters because a wrong filter here silently returns the wrong games rather
/// than failing.
library;

import 'game_authority.dart';

/// How results are ordered.
enum MasterGamesOrder {
  /// Most recent first — the default, because the interesting question is
  /// usually "what happened lately in my lines".
  newest,

  /// Highest rating first.
  strongest,
}

/// One browse request.
class MasterGamesQuery {
  const MasterGamesQuery({
    this.player,
    this.opponent,
    this.event,
    this.eco,
    this.minElo,
    this.fromDate,
    this.toDate,
    this.fromIssue,
    this.toIssue,
    this.authorities = const {},
    this.order = MasterGamesOrder.newest,
    this.limit = 200,
    this.offset = 0,
  });

  /// Either colour, matched as a case-insensitive prefix of the PGN name
  /// (`Carlsen` finds `Carlsen,Magnus`).
  final String? player;

  /// The other side, same matching.  Only meaningful with [player].
  final String? opponent;

  /// Substring of the event name.
  final String? event;

  /// ECO prefix: `B90`, or `B9`, or `B`.
  final String? eco;

  /// Both players must be at least this strong.
  final int? minElo;

  /// PGN dates, `YYYY.MM.DD`; compared as text, which sorts correctly.
  final String? fromDate;
  final String? toDate;

  final int? fromIssue;
  final int? toIssue;

  /// Which citation tiers to include; empty means all of them.  The useful
  /// setting is `{classical}`: over half the corpus is online blitz, and for
  /// "what are people playing against my line" that is either the most
  /// interesting half or the least, depending on who is asking.
  final Set<GameAuthority> authorities;

  final MasterGamesOrder order;
  final int limit;
  final int offset;

  MasterGamesQuery copyWith({
    String? player,
    String? opponent,
    String? event,
    String? eco,
    int? minElo,
    String? fromDate,
    String? toDate,
    int? fromIssue,
    int? toIssue,
    Set<GameAuthority>? authorities,
    MasterGamesOrder? order,
    int? limit,
    int? offset,
    bool clearPlayer = false,
    bool clearOpponent = false,
    bool clearEvent = false,
    bool clearEco = false,
    bool clearMinElo = false,
    bool clearDates = false,
  }) => MasterGamesQuery(
    player: clearPlayer ? null : (player ?? this.player),
    opponent: clearOpponent ? null : (opponent ?? this.opponent),
    event: clearEvent ? null : (event ?? this.event),
    eco: clearEco ? null : (eco ?? this.eco),
    minElo: clearMinElo ? null : (minElo ?? this.minElo),
    fromDate: clearDates ? null : (fromDate ?? this.fromDate),
    toDate: clearDates ? null : (toDate ?? this.toDate),
    fromIssue: fromIssue ?? this.fromIssue,
    toIssue: toIssue ?? this.toIssue,
    authorities: authorities ?? this.authorities,
    order: order ?? this.order,
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
  );

  /// True when nothing is restricted — the browser opens in this state.
  bool get isUnfiltered =>
      _blank(player) &&
      _blank(opponent) &&
      _blank(event) &&
      _blank(eco) &&
      minElo == null &&
      fromDate == null &&
      toDate == null &&
      fromIssue == null &&
      toIssue == null &&
      authorities.isEmpty;

  static bool _blank(String? s) => s == null || s.trim().isEmpty;
}

/// The WHERE clause and its arguments for [query], without the leading
/// `WHERE`.  An empty string means "no restriction".
({String where, List<Object?> args}) buildMasterGamesWhere(
  MasterGamesQuery query,
) {
  final clauses = <String>[];
  final args = <Object?>[];

  final player = query.player?.trim();
  final opponent = query.opponent?.trim();
  if (player != null && player.isNotEmpty) {
    if (opponent != null && opponent.isNotEmpty) {
      // Either seating of the pairing.
      clauses.add(
        '((white LIKE ? COLLATE NOCASE AND black LIKE ? COLLATE NOCASE) OR '
        '(white LIKE ? COLLATE NOCASE AND black LIKE ? COLLATE NOCASE))',
      );
      args.addAll(['$player%', '$opponent%', '$opponent%', '$player%']);
    } else {
      clauses.add(
        '(white LIKE ? COLLATE NOCASE OR black LIKE ? COLLATE NOCASE)',
      );
      args.addAll(['$player%', '$player%']);
    }
  } else if (opponent != null && opponent.isNotEmpty) {
    clauses.add('(white LIKE ? COLLATE NOCASE OR black LIKE ? COLLATE NOCASE)');
    args.addAll(['$opponent%', '$opponent%']);
  }

  final event = query.event?.trim();
  if (event != null && event.isNotEmpty) {
    clauses.add('event LIKE ? COLLATE NOCASE');
    args.add('%$event%');
  }

  final eco = query.eco?.trim();
  if (eco != null && eco.isNotEmpty) {
    clauses.add('eco LIKE ? COLLATE NOCASE');
    args.add('$eco%');
  }

  if (query.minElo != null) {
    // A missing rating is not a low one, but it cannot clear a floor either.
    clauses.add('COALESCE(white_elo, 0) >= ? AND COALESCE(black_elo, 0) >= ?');
    args.addAll([query.minElo, query.minElo]);
  }

  if (query.fromDate != null) {
    clauses.add('date >= ?');
    args.add(query.fromDate);
  }
  if (query.toDate != null) {
    clauses.add('date <= ?');
    args.add(query.toDate);
  }

  if (query.fromIssue != null) {
    clauses.add('twic >= ?');
    args.add(query.fromIssue);
  }
  if (query.toIssue != null) {
    clauses.add('twic <= ?');
    args.add(query.toIssue);
  }

  if (query.authorities.isNotEmpty &&
      query.authorities.length < GameAuthority.values.length) {
    final codes = query.authorities.map((a) => a.code).toList()..sort();
    clauses.add('authority IN (${List.filled(codes.length, '?').join(',')})');
    args.addAll(codes);
  }

  return (where: clauses.join(' AND '), args: args);
}

/// `ORDER BY` for [order].
String masterGamesOrderBy(MasterGamesOrder order) => switch (order) {
  // `id` breaks ties so paging is stable: two games from the same day must
  // not swap places between one page and the next.
  MasterGamesOrder.newest => 'date DESC, id DESC',
  MasterGamesOrder.strongest =>
    'MAX(COALESCE(white_elo, 0), COALESCE(black_elo, 0)) DESC, id DESC',
};
