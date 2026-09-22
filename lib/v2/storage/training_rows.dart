/// The four training files and the shape of their rows, shared with the old
/// app, which reads and writes the same files on the same profile.
///
/// The three CSVs open with a header row. A record written before the old
/// app's quoting migration may carry a chapter path with commas in it
/// unquoted; the header's width is what tells such a record apart, so a file
/// without a header is not read. Reviews come in three widths — 8 and 10
/// columns from older versions, 11 now — and are written at 11.
library;

import 'dart:convert';

import '../chess/fen.dart';
import '../chess/training/records.dart';
import '../chess/training/schedule.dart';
import 'csv_records.dart';

const reviewsFile = 'repertoire_reviews.csv';
const streaksFile = 'repertoire_move_progress.csv';
const historyFile = 'repertoire_review_history.csv';
const attemptsFile = 'repertoire_move_attempts.jsonl';

const reviewsHeader =
    'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
    'last_rating,last_reviewed_utc,pass_count,fail_count,excluded';
const streaksHeader = 'repertoire_id,line_id,move_index,correct_streak,learned';
const historyHeader =
    'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';

/// The first column of every CSV, and of their headers.
const idColumn = 'repertoire_id';

/// The width the header declares, or null when the file has no header.
int? headerWidth(List<CsvRecord> records) {
  for (final record in records) {
    if (record.isBlank) continue;
    return record.fields.first == idColumn ? record.fields.length : null;
  }
  return null;
}

/// The cells of a record that names a chapter, or null for the header and
/// for blank lines. [width] is how many columns the record should have; null
/// when nothing says, and the cells are taken as they are.
List<String>? dataCells(CsvRecord record, int? width) {
  if (record.isBlank || record.fields.first == idColumn) return null;
  return width == null || record.source.startsWith('"')
      ? record.fields
      : _rejoinLegacyPath(record.fields, width);
}

/// Writers before the quoting migration put the chapter path in unquoted,
/// commas and all, so a path with a comma spilled into the columns after it.
/// Every later column has a fixed position, so the path is whatever is left
/// once they are accounted for.
List<String> _rejoinLegacyPath(List<String> cells, int width) {
  if (cells.length <= width) return cells;
  final spilled = cells.length - width + 1;
  return [cells.take(spilled).join(','), ...cells.skip(spilled)];
}

/// A review row, or null when the cells are not one.
Review? decodeReview(List<String> cells) {
  if (cells.length != 8 && cells.length != 10 && cells.length != 11) {
    return null;
  }
  final ease = double.tryParse(cells[3]);
  final interval = double.tryParse(cells[4]);
  final passes = cells.length > 8 ? int.tryParse(cells[8]) : 0;
  final fails = cells.length > 9 ? int.tryParse(cells[9]) : 0;
  if (ease == null || interval == null || passes == null || fails == null) {
    return null;
  }
  return Review(
    key: (source: cells[0], id: cells[1]),
    lineName: cells[2],
    ease: ease,
    intervalDays: interval,
    due: _time(cells[5]),
    lastRating: cells[6],
    lastReviewed: _time(cells[7]),
    passes: passes,
    fails: fails,
    excluded: cells.length > 10 && cells[10] == 'true',
  );
}

List<String> encodeReview(Review review) => [
  review.key.source,
  review.key.id,
  review.lineName,
  review.ease.toStringAsFixed(2),
  review.intervalDays.toStringAsFixed(2),
  review.due?.toUtc().toIso8601String() ?? '',
  review.lastRating,
  review.lastReviewed?.toUtc().toIso8601String() ?? '',
  '${review.passes}',
  '${review.fails}',
  '${review.excluded}',
];

/// [review] as the file will hold it: two decimals, times to the
/// millisecond in UTC. What is kept in memory after a write, so the next
/// write can tell its own row from somebody else's.
Review asWritten(Review review) => decodeReview(encodeReview(review))!;

MoveStreak? decodeStreak(List<String> cells) {
  if (cells.length != 5) return null;
  final ply = int.tryParse(cells[2]);
  final streak = int.tryParse(cells[3]);
  if (ply == null || streak == null) return null;
  return MoveStreak(
    key: (source: cells[0], id: cells[1]),
    ply: ply,
    streak: streak,
    learned: cells[4] == '1',
  );
}

List<String> encodeStreak(MoveStreak streak) => [
  streak.key.source,
  streak.key.id,
  '${streak.ply}',
  '${streak.streak}',
  streak.learned ? '1' : '0',
];

List<String> encodeHistory(HistoryRow row) => [
  row.key.source,
  row.key.id,
  row.at.toUtc().toIso8601String(),
  row.rating,
  row.mistake ? '1' : '0',
  row.kind.name,
];

String encodeAttempt(Attempt attempt) => jsonEncode({
  'repertoireId': attempt.key.source,
  'lineId': attempt.key.id,
  'moveIndex': attempt.ply,
  'fen': attempt.fen.value,
  'playedSan': attempt.played,
  'expectedSan': attempt.expected,
  'correct': attempt.correct,
  'phase': attempt.phase.name,
  'timestampUtc': attempt.at.toUtc().toIso8601String(),
});

/// One line of the attempt log, or null when it is not an answer this app
/// can show. The old app writes the same keys.
Attempt? decodeAttempt(String line) {
  final Object? json;
  try {
    json = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (json case {
    'repertoireId': final String source,
    'lineId': final String id,
    'moveIndex': final int ply,
    'fen': final String fen,
    'playedSan': final String played,
    'expectedSan': final String expected,
    'correct': final bool correct,
    'phase': final String phase,
    'timestampUtc': final String at,
  }) {
    final time = _time(at);
    if (time == null) return null;
    return Attempt(
      key: (source: source, id: id),
      ply: ply,
      fen: Fen(fen),
      played: played,
      expected: expected,
      correct: correct,
      phase: AttemptPhase.values.asNameMap()[phase] ?? AttemptPhase.drilling,
      at: time,
    );
  }
  return null;
}

DateTime? _time(String text) =>
    text.isEmpty ? null : DateTime.tryParse(text)?.toUtc();
