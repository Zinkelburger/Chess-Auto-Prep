/// Shared game-selection semantics for the unified Games library.
///
/// Tactics, the weakness finder, and the repertoire builder all want the same
/// thing: "give me my last N games" or "everything since some date", optionally
/// restricted to certain time controls, with duplicates removed. That logic
/// lived nowhere shared. This module defines it once, as pure functions over
/// parsed [GameRecord]s, so every feature enforces identical rules.
///
/// Pure / synchronous — fully unit-testable.
library;

import '../game_identity.dart';
import '../pgn_parsing_service.dart' show splitPgnIntoGames, extractHeaders;

/// Lichess-style speed bucket, derived from the TimeControl header.
enum GameSpeed {
  ultraBullet,
  bullet,
  blitz,
  rapid,
  classical,
  correspondence,
  unknown,
}

/// The one place a speed bucket gets its name, its plain-English range and
/// its Lichess API spelling. Three screens each had their own switch over
/// [GameSpeed] before this; the labels had already started to differ.
extension GameSpeedInfo on GameSpeed {
  /// Display name ("Bullet", "Correspondence").
  String get label => switch (this) {
    GameSpeed.ultraBullet => 'UltraBullet',
    GameSpeed.bullet => 'Bullet',
    GameSpeed.blitz => 'Blitz',
    GameSpeed.rapid => 'Rapid',
    GameSpeed.classical => 'Classical',
    GameSpeed.correspondence => 'Correspondence',
    GameSpeed.unknown => 'Unknown',
  };

  /// The bucket's range in a player's terms, for a caption under [label].
  /// The boundaries are Lichess' estimated game length, base + 40 × increment.
  String get rangeDescription => switch (this) {
    GameSpeed.ultraBullet => 'Under 30 seconds',
    GameSpeed.bullet => 'Under 3 minutes',
    GameSpeed.blitz => '3 to 8 minutes',
    GameSpeed.rapid => '8 to 25 minutes',
    GameSpeed.classical => '25 minutes and longer',
    GameSpeed.correspondence => 'Days per move',
    GameSpeed.unknown => 'No time control recorded',
  };

  /// The value the Lichess games export takes in `perfType`, or null for a
  /// bucket the API has no name for.
  String? get lichessPerfType => switch (this) {
    GameSpeed.ultraBullet => 'ultraBullet',
    GameSpeed.bullet => 'bullet',
    GameSpeed.blitz => 'blitz',
    GameSpeed.rapid => 'rapid',
    GameSpeed.classical => 'classical',
    GameSpeed.correspondence => 'correspondence',
    GameSpeed.unknown => null,
  };
}

/// Every bucket a user can pick, slowest last; [GameSpeed.unknown] is not a
/// choice, it is what a game without a TimeControl header gets.
const List<GameSpeed> selectableGameSpeeds = [
  GameSpeed.ultraBullet,
  GameSpeed.bullet,
  GameSpeed.blitz,
  GameSpeed.rapid,
  GameSpeed.classical,
  GameSpeed.correspondence,
];

/// Parse the `name`s a [Set<GameSpeed>] was persisted as, ignoring anything
/// unrecognised. Null in, null out, so a caller can fall back to its default.
Set<GameSpeed>? gameSpeedsFromNames(Iterable<String>? names) {
  if (names == null) return null;
  return {
    for (final name in names)
      for (final s in GameSpeed.values)
        if (s.name == name) s,
  };
}

/// Classify a PGN `TimeControl` header value into a [GameSpeed].
///
/// Uses Lichess' estimated-duration rule: `base + 40 * increment` seconds.
GameSpeed classifySpeed(String? timeControl) {
  if (timeControl == null || timeControl.trim().isEmpty) {
    return GameSpeed.unknown;
  }
  final tc = timeControl.trim();
  // Correspondence: "-" (unlimited) or days-per-move "1/259200".
  if (tc == '-' || tc.contains('/')) return GameSpeed.correspondence;

  final plus = tc.split('+');
  final base = int.tryParse(plus[0]);
  if (base == null) return GameSpeed.unknown;
  final inc = plus.length > 1 ? (int.tryParse(plus[1]) ?? 0) : 0;
  final estimated = base + 40 * inc;

  if (estimated < 30) return GameSpeed.ultraBullet;
  if (estimated < 180) return GameSpeed.bullet;
  if (estimated < 480) return GameSpeed.blitz;
  if (estimated < 1500) return GameSpeed.rapid;
  return GameSpeed.classical;
}

/// A single parsed game with the bits the filter needs.
class GameRecord {
  GameRecord({
    required this.pgn,
    required this.headers,
    required this.date,
    required this.speed,
    required this.dedupKey,
  });

  final String pgn;
  final Map<String, String> headers;

  /// UTC date+time the game was played, when derivable (for ordering / since).
  final DateTime? date;
  final GameSpeed speed;

  /// Stable identity for de-duplication (site URL, else players+date+time).
  final String dedupKey;

  String get white => headers['White'] ?? '?';
  String get black => headers['Black'] ?? '?';

  static GameRecord parse(String singleGamePgn) {
    final headers = extractHeaders(singleGamePgn);
    return GameRecord(
      pgn: singleGamePgn,
      headers: headers,
      date: _parseDate(headers),
      speed: classifySpeed(headers['TimeControl']),
      dedupKey: dedupKeyForHeaders(headers, pgn: singleGamePgn),
    );
  }

  static DateTime? _parseDate(Map<String, String> h) {
    final date = h['UTCDate'] ?? h['Date'];
    if (date == null) return null;
    final dm = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})').firstMatch(date.trim());
    if (dm == null) return null;
    final y = int.tryParse(dm.group(1)!);
    final mo = int.tryParse(dm.group(2)!);
    final d = int.tryParse(dm.group(3)!);
    if (y == null || mo == null || d == null || mo < 1 || mo > 12) return null;
    int hh = 0, mm = 0, ss = 0;
    final time = h['UTCTime'] ?? h['Time'];
    if (time != null) {
      final tm = RegExp(r'^(\d{2}):(\d{2}):(\d{2})').firstMatch(time.trim());
      if (tm != null) {
        hh = int.tryParse(tm.group(1)!) ?? 0;
        mm = int.tryParse(tm.group(2)!) ?? 0;
        ss = int.tryParse(tm.group(3)!) ?? 0;
      }
    }
    try {
      return DateTime.utc(y, mo, d, hh, mm, ss);
    } catch (_) {
      return null;
    }
  }
}

/// Stable game identity from PGN headers: the game URL when present, else
/// players + date + time. Public so consumers holding headers from another
/// parser (e.g. the PGN viewer locating a `gameId` handoff target) compute
/// the same identity the library's [GameRecord.dedupKey] uses.
String dedupKeyForHeaders(Map<String, String> h, {String pgn = ''}) =>
    canonicalGameKey(h, pgn, preferHeaderId: false);

/// Merge a freshly downloaded multi-game PGN into an existing cache file's
/// content, preserving the existing games' text *verbatim* — they may carry
/// locally added analysis annotations (`[%eval]` comments written by the PGN
/// viewer's game review) that a wholesale rewrite would destroy. Genuinely
/// new games (by [GameRecord.dedupKey]) are appended after the existing ones
/// so game order stays stable for anything referencing the file.
///
/// [maxGames] caps the merged file, dropping the *oldest* games once it is
/// exceeded — without it the cache only ever grows, and every read re-parses
/// the whole history. Survivors keep their existing relative order, so the
/// cap reorders nothing. Null (the default) keeps everything.
String mergeGamePgns({
  required String existing,
  required String fresh,
  int? maxGames,
}) {
  final existingChunks = splitPgnIntoGames(existing);
  final seen = existingChunks
      .map((c) => dedupKeyForHeaders(extractHeaders(c), pgn: c))
      .toSet();
  final newGames = <String>[
    for (final chunk in splitPgnIntoGames(fresh))
      if (seen.add(dedupKeyForHeaders(extractHeaders(chunk), pgn: chunk)))
        chunk.trim(),
  ];

  final merged = <String>[
    for (final chunk in existingChunks) chunk.trim(),
    ...newGames,
  ];
  if (maxGames == null || merged.length <= maxGames) {
    if (newGames.isEmpty) return existing;
    final base = existing.trimRight();
    if (base.isEmpty) return newGames.join('\n\n');
    return '$base\n\n${newGames.join('\n\n')}';
  }

  // Over the cap: keep the newest [maxGames] by date, then re-emit them in
  // the order they already sat in the file.
  final records = merged.map(GameRecord.parse).toList();
  final byAge = [...records];
  _sortNewestFirst(byAge);
  final keep = byAge.take(maxGames).map((r) => r.dedupKey).toSet();
  return [
    for (final record in records)
      if (keep.contains(record.dedupKey) || _hasAnnotations(record.pgn))
        record.pgn.trim(),
  ].join('\n\n');
}

/// What slice of a player's games to keep.
class GameSelection {
  const GameSelection({
    this.maxGames,
    this.since,
    this.speeds = const {GameSpeed.blitz, GameSpeed.rapid, GameSpeed.classical},
  });

  /// Keep at most this many of the most-recent games (after other filters).
  final int? maxGames;

  /// Keep only games on/after this UTC instant.
  final DateTime? since;

  /// Keep only games in these speed buckets. Empty = all speeds.
  final Set<GameSpeed> speeds;

  bool allowsSpeed(GameSpeed s) => speeds.isEmpty || speeds.contains(s);
}

/// Parse a multi-game PGN into records (newest first when dates are present).
List<GameRecord> parseGameRecords(String multiGamePgn) {
  final records = splitPgnIntoGames(
    multiGamePgn,
  ).map(GameRecord.parse).toList();
  _sortNewestFirst(records);
  return records;
}

/// Apply a [GameSelection]: speed filter → since filter → de-dup → newest-first
/// → cap to [GameSelection.maxGames].
List<GameRecord> applySelection(
  List<GameRecord> records,
  GameSelection selection,
) {
  final seen = <String>{};
  final out = <GameRecord>[];
  final sorted = [...records];
  _sortNewestFirst(sorted);

  for (final r in sorted) {
    if (!selection.allowsSpeed(r.speed)) continue;
    if (selection.since != null) {
      if (r.date == null || r.date!.isBefore(selection.since!)) continue;
    }
    if (!seen.add(r.dedupKey)) continue;
    out.add(r);
    if (selection.maxGames != null && out.length >= selection.maxGames!) break;
  }
  return out;
}

/// The union of [applySelection] over [selections]: a game is kept when any
/// one selection keeps it. De-duplicated, newest first — the shape a caller
/// needs to serve several windows from a single parse (the games home builds
/// its last-N-games and last-N-days slices together this way, so flipping
/// the window mode never re-runs the pipeline).
List<GameRecord> applySelectionUnion(
  List<GameRecord> records,
  List<GameSelection> selections,
) {
  final seen = <String>{};
  final out = <GameRecord>[];
  for (final selection in selections) {
    for (final record in applySelection(records, selection)) {
      if (seen.add(record.dedupKey)) out.add(record);
    }
  }
  _sortNewestFirst(out);
  return out;
}

void _sortNewestFirst(List<GameRecord> records) {
  records.sort((a, b) {
    final da = a.date, db = b.date;
    if (da == null && db == null) return 0;
    if (da == null) return 1; // undated sinks to the bottom
    if (db == null) return -1;
    return db.compareTo(da);
  });
}

/// Comments, variations, NAGs and custom tags may be user-authored. Keep them
/// even beyond the download window; they are not reproducible cache entries.
bool _hasAnnotations(String pgn) {
  if (RegExp(
    r'[{}();]|\$[0-9]+|[!?]',
  ).hasMatch(pgn.replaceAll(RegExp(r'\[[^\n]*\]'), ''))) {
    return true;
  }
  final headers = extractHeaders(pgn);
  const downloadTags = {
    'Event',
    'Site',
    'Date',
    'Round',
    'White',
    'Black',
    'Result',
    'UTCDate',
    'UTCTime',
    'Time',
    'WhiteElo',
    'BlackElo',
    'ECO',
    'Opening',
    'Variation',
    'TimeControl',
    'Termination',
    'Link',
    'GameId',
    'EndDate',
    'EndTime',
    'StartTime',
    'Timezone',
    'WhiteUrl',
    'BlackUrl',
    'CurrentPosition',
    'FEN',
    'SetUp',
  };
  return headers.keys.any((key) => !downloadTags.contains(key));
}
