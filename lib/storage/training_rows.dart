/// The four training files and the shape of their rows.
///
/// The three CSVs open with a header row and quote any field holding a
/// comma, a quote or a newline. Reviews have 11 columns.
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

/// The four files, in the order every record and plan lists them.
const trainingParticipants = [
  reviewsFile,
  streaksFile,
  historyFile,
  attemptsFile,
];

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

/// Whether [cells] of the CSV [file] are a whole row this app can read: a
/// review or streak row must decode, and any other row has the width its
/// header declares.
bool isWholeRow(String file, List<String> cells, int? header) => switch (file) {
  reviewsFile => decodeReview(cells) != null,
  streaksFile => decodeStreak(cells) != null,
  _ => cells.length == header,
};

/// Whether the text of a record this app cannot read may name [path], or a
/// path inside it: as written, with its quotes doubled inside a quoted CSV
/// field, or escaped as a JSON string, which is how the log spells a Windows
/// path. A Windows path is also sought with forward slashes, which name the
/// same file there. Matching ignores case, so a doubtful record is taken to
/// name it.
bool mayName(String raw, String path) {
  final text = raw.toLowerCase();
  return {path, path.replaceAll(r'\', '/')}.any((written) {
    final json = jsonEncode(written);
    return [
      written,
      written.replaceAll('"', '""'),
      json.substring(1, json.length - 1),
    ].any((spelling) => text.contains(spelling.toLowerCase()));
  });
}

/// The header the file [file] is written with.
String headerOf(String file) => switch (file) {
  reviewsFile => reviewsHeader,
  streaksFile => streaksHeader,
  historyFile => historyHeader,
  _ => throw ArgumentError.value(file, 'file', 'not a training CSV'),
};

/// The cells of a record that names a chapter, or null for the header and
/// for blank lines.
List<String>? dataCells(CsvRecord record) =>
    record.isBlank || record.fields.first == idColumn ? null : record.fields;

/// A review row, or null when the cells are not one.
Review? decodeReview(List<String> cells) {
  if (cells.length != 11) return null;
  final ease = double.tryParse(cells[3]);
  final interval = double.tryParse(cells[4]);
  final passes = int.tryParse(cells[8]);
  final fails = int.tryParse(cells[9]);
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
    excluded: cells[10] == 'true',
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
/// can show. Existing logs carry these same keys.
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
