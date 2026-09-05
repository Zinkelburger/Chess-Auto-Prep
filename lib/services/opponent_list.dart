/// The opponent list: a file naming the people you are about to play and the
/// online accounts that are theirs, produced outside the app (the
/// `tools/mcp/chess_prep` server, a script, or by hand) and imported into
/// Player Analysis, where each opponent becomes an ordinary player entry.
///
/// Wire format (`chess-auto-prep/opponents@1`, written by
/// `tools/mcp/chess_prep/opponents.py`):
///
/// ```json
/// {
///   "format": "chess-auto-prep/opponents@1",
///   "event": "Spring Open 2026",
///   "opponents": [
///     {"name": "Jane Doe", "chesscom": "janed", "lichess": "jd_li",
///      "rating": 1850, "pairing_prob": 0.42, "most_likely_round": 2}
///   ]
/// }
/// ```
///
/// Only `name` and at least one of `chesscom` / `lichess` are required. A bare
/// JSON array of opponents is also accepted, so a hand-written list needs no
/// envelope. Everything beyond names and accounts is advisory: it is shown to
/// the user and never changes what gets downloaded.
library;

import 'dart:convert';

import '../models/analysis_player_info.dart';
import 'games_library/game_filter.dart';

/// The format tag this app writes and the Python tooling checks against.
const kOpponentListFormat = 'chess-auto-prep/opponents@1';

/// One entrant: a person plus the accounts their games come from.
class OpponentEntry {
  final String name;
  final String? chesscom;
  final String? lichess;
  final int? rating;
  final String? title;

  /// P(you face them at all), from a pairing simulation. Null when the list
  /// carries no odds.
  final double? pairingProb;
  final int? mostLikelyRound;
  final String? note;

  const OpponentEntry({
    required this.name,
    this.chesscom,
    this.lichess,
    this.rating,
    this.title,
    this.pairingProb,
    this.mostLikelyRound,
    this.note,
  });

  List<PlayerAccount> get accounts => [
    if (chesscom != null && chesscom!.isNotEmpty)
      PlayerAccount('chesscom', chesscom!),
    if (lichess != null && lichess!.isNotEmpty)
      PlayerAccount('lichess', lichess!),
  ];

  bool get hasAccount => accounts.isNotEmpty;

  /// The stored player name: the person first, then every handle, so the
  /// analysis matches whichever spelling a game header uses (see
  /// `userNameMatchesHeader`) and the picker can still show just the person.
  String get playerName => [
    name.trim(),
    for (final a in accounts)
      if (a.username.toLowerCase() != name.trim().toLowerCase()) a.username,
  ].join('; ');

  /// The player entry this opponent is stored as. Always the `'import'`
  /// platform: the game-set may merge two sites, and nothing else in the app
  /// should treat a person's name as a live username.
  AnalysisPlayerInfo toPlayerInfo({
    required String? group,
    required int maxGames,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
  }) => AnalysisPlayerInfo(
    platform: 'import',
    username: playerName,
    maxGames: maxGames,
    monthsBack: monthsBack,
    speeds: speeds,
    accounts: accounts,
    group: group,
  );

  /// One-line summary for lists: rating, odds, round.
  String get summary {
    final parts = <String>[
      if (title != null && title!.isNotEmpty) title!,
      if (rating != null) '$rating',
      if (pairingProb != null)
        '${(pairingProb! * 100).toStringAsFixed(0)}% to face',
      if (mostLikelyRound != null) 'likely round $mostLikelyRound',
    ];
    return parts.join(' · ');
  }
}

/// A parsed opponent list plus anything the parser had to skip.
class OpponentList {
  final String? event;
  final List<OpponentEntry> opponents;

  /// Rows that could not be used, with the reason — surfaced rather than
  /// dropped so a typo in one row is visible instead of a silent gap.
  final List<String> warnings;

  const OpponentList({
    required this.event,
    required this.opponents,
    this.warnings = const [],
  });

  /// Opponents with at least one account — the ones a download can act on.
  List<OpponentEntry> get downloadable =>
      opponents.where((o) => o.hasAccount).toList();

  /// Parse JSON text. Throws [FormatException] when the text is not JSON or
  /// has no recognisable opponent rows at all; per-row problems become
  /// [warnings] instead.
  static OpponentList parse(String text) {
    final Object? decoded;
    try {
      decoded = json.decode(text);
    } on FormatException catch (e) {
      throw FormatException('Not valid JSON: ${e.message}');
    }

    String? event;
    final List<Object?> rows;
    if (decoded is Map) {
      final format = decoded['format'];
      if (format is String &&
          format.isNotEmpty &&
          format != kOpponentListFormat) {
        throw FormatException(
          'Unknown format "$format" (expected $kOpponentListFormat).',
        );
      }
      event = (decoded['event'] as String?)?.trim();
      if (event != null && event.isEmpty) event = null;
      final list = decoded['opponents'];
      if (list is! List) {
        throw const FormatException(
          'Expected an "opponents" array (or a bare JSON array).',
        );
      }
      rows = list;
    } else if (decoded is List) {
      rows = decoded;
    } else {
      throw const FormatException(
        'Expected an object with an "opponents" array, or a JSON array.',
      );
    }

    final opponents = <OpponentEntry>[];
    final warnings = <String>[];
    final seen = <String>{};

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! Map) {
        warnings.add('Row ${i + 1}: not an object — skipped.');
        continue;
      }
      final name = _string(row['name']);
      if (name == null) {
        warnings.add('Row ${i + 1}: missing "name" — skipped.');
        continue;
      }
      final entry = OpponentEntry(
        name: name,
        chesscom: _string(row['chesscom'] ?? row['chesscom_username']),
        lichess: _string(row['lichess'] ?? row['lichess_username']),
        rating: _int(row['rating']),
        title: _string(row['title']),
        pairingProb: _double(row['pairing_prob'] ?? row['pairingProb']),
        mostLikelyRound: _int(
          row['most_likely_round'] ?? row['mostLikelyRound'],
        ),
        note: _string(row['note']),
      );
      if (!entry.hasAccount) {
        warnings.add('$name: no chess.com or lichess account — skipped.');
        continue;
      }
      final key = entry.playerName.toLowerCase();
      if (!seen.add(key)) {
        warnings.add('$name: listed twice — second row ignored.');
        continue;
      }
      opponents.add(entry);
    }

    if (opponents.isEmpty && warnings.isEmpty) {
      throw const FormatException('The list has no opponents.');
    }
    return OpponentList(event: event, opponents: opponents, warnings: warnings);
  }

  static String? _string(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static int? _int(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static double? _double(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }
}
