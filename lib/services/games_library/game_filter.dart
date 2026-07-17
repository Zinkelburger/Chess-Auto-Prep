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
      dedupKey: _dedupKey(headers),
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

  static String _dedupKey(Map<String, String> h) {
    final link = h['Link'] ?? h['Site'];
    if (link != null && link.contains('://')) return link.trim();
    return [
      h['White'] ?? '',
      h['Black'] ?? '',
      h['UTCDate'] ?? h['Date'] ?? '',
      h['UTCTime'] ?? h['Time'] ?? '',
    ].join('|');
  }
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

/// Serialize records back into a multi-game PGN string.
String recordsToPgn(List<GameRecord> records) =>
    records.map((r) => r.pgn.trim()).join('\n\n');

void _sortNewestFirst(List<GameRecord> records) {
  records.sort((a, b) {
    final da = a.date, db = b.date;
    if (da == null && db == null) return 0;
    if (da == null) return 1; // undated sinks to the bottom
    if (db == null) return -1;
    return db.compareTo(da);
  });
}
