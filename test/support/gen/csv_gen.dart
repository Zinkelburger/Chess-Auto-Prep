/// Training files for the codec laws, each generated with its truth: the
/// records a reader must find in it, where each starts, and whether a
/// quoted field is left open.
///
/// Rows come in the spellings the two apps have written over the years:
/// canonical, quoted more than they need to be, and the unquoted rows from
/// before the quoting migration, whose chapter path may hold a comma. Review
/// rows come 8, 10 and 11 columns wide. Around them sit blank lines, lines
/// of empty cells, junk, CRLF and LF endings, and a last line with or
/// without its newline.
library;

import 'dart:convert';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';

import '../props.dart';
import 'json_gen.dart';

/// Chapter paths as the files hold them: plain, with a comma, with quotes
/// inside, Windows spellings and non-ASCII.
const csvSources = [
  '/home/u/Documents/repertoires/KID/Main.pgn',
  '/home/u/Documents/repertoires/Open, Closed/Main.pgn',
  '/home/u/Documents/repertoires/My "KID" line.pgn',
  r'C:\Users\u\Documents\repertoires\Benko\Main.pgn',
  '/home/u/Документы/repertoires/Сицилианская.pgn',
];

/// Line names: plain, and ones that need quoting.
const csvNames = [
  'Mainline',
  'Open, Closed',
  'with "quotes"',
  'two\nlines',
  ' padded ',
  '',
];

/// How a data row is spelled in the file.
enum RowSpelling {
  /// As this app writes it: quoted only where a field needs it.
  canonical,

  /// Every field quoted, as a spreadsheet may save it.
  quoted,

  /// Fields joined with commas and never quoted, as writers before the
  /// quoting migration did; a comma in the path spills into later cells.
  legacy,
}

/// A record as the file holds it and as the reader must find it.
typedef CsvTruth = ({
  String source,
  String terminator,
  int line,
  List<String> fields,
});

/// A generated CSV text and its truth.
final class GeneratedCsv {
  GeneratedCsv(this.records, {this.open});

  /// Every record in order, [CsvTruth.line] counted from the text.
  final List<CsvTruth> records;

  /// A last line opening a quoted field it never closes, or null.
  final String? open;

  String get text =>
      '${records.map((r) => '${r.source}${r.terminator}').join()}'
      '${open ?? ''}';

  /// The line the open quote starts on, or null when every field closes.
  int? get unclosedLine => open == null
      ? null
      : 1 +
            records.fold(
              0,
              (n, r) => n + _newlines('${r.source}${r.terminator}'),
            );

  /// This text without its [i]th record, the lines after it renumbered.
  GeneratedCsv without(int i) {
    final kept = <CsvTruth>[];
    var line = 1;
    for (final r in [...records]..removeAt(i)) {
      kept.add((
        source: r.source,
        terminator: r.terminator,
        line: line,
        fields: r.fields,
      ));
      line += _newlines('${r.source}${r.terminator}');
    }
    return GeneratedCsv(kept, open: open);
  }

  GeneratedCsv withoutOpen() => GeneratedCsv(records);

  @override
  String toString() => jsonEncode(text);
}

int _newlines(String text) => '\n'.allMatches(text).length;

/// [rows] as file text: each given a terminator, CRLF about [crlf] percent
/// of the time, the last without one when [finalNewline] is false.
GeneratedCsv csvOf(
  Rand rand,
  List<({String source, List<String> fields})> rows, {
  int crlf = 30,
  bool finalNewline = true,
  String? open,
}) {
  final records = <CsvTruth>[];
  var line = 1;
  for (final (index, row) in rows.indexed) {
    final last = index == rows.length - 1 && open == null;
    final terminator = last && !finalNewline && row.source.isNotEmpty
        ? ''
        : rand.chance(crlf)
        ? '\r\n'
        : '\n';
    records.add((
      source: row.source,
      terminator: terminator,
      line: line,
      fields: row.fields,
    ));
    line += _newlines('${row.source}$terminator');
  }
  return GeneratedCsv(records, open: open);
}

/// [cells] as one record spelled [spelling], and the fields a CSV reader
/// finds in it — for a legacy row, the path split at its commas.
({String source, List<String> fields}) spelledRow(
  List<String> cells,
  RowSpelling spelling,
) => switch (spelling) {
  RowSpelling.canonical => (source: encodeCsvRecord(cells), fields: cells),
  RowSpelling.quoted => (
    source: cells.map((c) => '"${c.replaceAll('"', '""')}"').join(','),
    fields: cells,
  ),
  RowSpelling.legacy => (
    source: cells.join(','),
    fields: cells.join(',').split(','),
  ),
};

/// Whether [cells] can be written unquoted and read back: only the path, the
/// first cell, may hold a comma, and nothing may hold a newline or open with
/// a quote.
bool legacyWritable(List<String> cells) =>
    cells.every((c) => !c.contains('\n') && !c.startsWith('"')) &&
    cells.skip(1).every((c) => !c.contains(','));

/// A time as the files write it, or null.
DateTime? csvTime(Rand rand) => rand.chance(25)
    ? null
    : DateTime.utc(2026, 1, 1).add(
        Duration(
          seconds: rand.between(-2000000000, 2000000000),
          milliseconds: rand.between(0, 999),
          microseconds: rand.chance(20) ? rand.between(1, 999) : 0,
        ),
      );

/// A review of any line, with values the scheduler or a person could
/// have left.
Review csvReview(Rand rand, {LineKey? key}) => Review(
  key: key ?? (source: rand.pick(csvSources), id: _lineId(rand)),
  lineName: rand.pick(csvNames),
  ease: rand.pick(const [2.5, 1.3, 3.0, 2.345, 0.0, 1e-3, 123.456]),
  intervalDays: rand.pick(const [0.0, 1.0, 6.0, 0.5, 25.004, 365.25, 1e6]),
  due: csvTime(rand),
  lastRating: rand.pick(const ['', 'again', 'hard', 'good', 'easy']),
  lastReviewed: csvTime(rand),
  passes: rand.between(0, 40),
  fails: rand.between(0, 40),
  excluded: rand.chance(20),
);

String _lineId(Rand rand) =>
    rand.pick(const ['line_1', 'line_2', 'a1b2c3d4', 'Line With Space']);

/// [review]'s cells cut to the [width] an older version wrote: 8 without
/// the counts and the exclusion, 10 without the exclusion.
List<String> reviewCells(Review review, int width) =>
    encodeReview(review).take(width).toList();

/// The review a row of [width] columns holding [review] reads as: the
/// columns it has not got take their defaults.
Review reviewAtWidth(Review review, int width) {
  final written = asWritten(review);
  return Review(
    key: written.key,
    lineName: written.lineName,
    ease: written.ease,
    intervalDays: written.intervalDays,
    due: written.due,
    lastRating: written.lastRating,
    lastReviewed: written.lastReviewed,
    passes: width > 8 ? written.passes : 0,
    fails: width > 9 ? written.fails : 0,
    excluded: width > 10 && written.excluded,
  );
}

/// A streak of any move.
MoveStreak csvStreak(Rand rand, {LineKey? key, int? ply}) => MoveStreak(
  key: key ?? (source: rand.pick(csvSources), id: _lineId(rand)),
  ply: ply ?? rand.between(0, 30),
  streak: rand.between(0, 9),
  learned: rand.nextBool(),
);

/// A record that is not a row: a blank line, one of spaces, a line of empty
/// cells as a spreadsheet leaves, or junk.
({String source, List<String> fields}) csvFiller(Rand rand) =>
    switch (rand.nextInt(6)) {
      0 => (source: '', fields: const <String>[]),
      1 => (source: '   ', fields: const <String>[]),
      2 => (source: ',,,,,,', fields: const <String>[]),
      3 => (source: 'x,y', fields: const ['x', 'y']),
      4 => (source: 'just text', fields: const ['just text']),
      _ => (
        source: '${csvSources.first},line_9,not,a,row',
        fields: [csvSources.first, 'line_9', 'not', 'a', 'row'],
      ),
    };

/// Any review file: a header of 8, 10 or 11 columns over rows of every
/// width and spelling, with filler between them and, now and then, a last
/// line that opens a quote and never closes it.
final Generator<GeneratedCsv> reviewCsvs = Generator(
  (rand) {
    final width = rand.pick(const [11, 11, 10, 8]);
    final header = reviewsHeader.split(',').take(width).toList();
    final rows = [
      (source: header.join(','), fields: header),
      for (var i = rand.between(0, 8); i > 0; i--)
        rand.chance(25) ? csvFiller(rand) : _reviewRow(rand),
    ];
    return csvOf(
      rand,
      rows,
      finalNewline: rand.chance(70),
      open: rand.chance(15) ? '"${csvSources.first},line_1,unclosed' : null,
    );
  },
  shrinker: (csv) sync* {
    if (csv.open != null) yield csv.withoutOpen();
    for (var i = csv.records.length - 1; i > 0; i--) {
      yield csv.without(i);
    }
  },
);

({String source, List<String> fields}) _reviewRow(Rand rand) {
  final width = rand.pick(const [11, 11, 10, 8]);
  final cells = reviewCells(csvReview(rand), width);
  var spelling = rand.pick(RowSpelling.values);
  if (spelling == RowSpelling.legacy && !legacyWritable(cells)) {
    spelling = RowSpelling.canonical;
  }
  return spelledRow(cells, spelling);
}

/// A line of the answer log, and the answer it holds: null for a line that
/// is not one this app can show.
typedef AttemptLine = ({String line, Attempt? truth});

/// Any line of the answer log: an answer as either app writes it, one with
/// fields a newer build added, or one that is not an answer at all.
final Generator<AttemptLine> attemptLines = Generator((rand) {
  final attempt = _attempt(rand);
  final json = jsonDecode(encodeAttempt(attempt)) as Map<String, Object?>;
  return switch (rand.nextInt(8)) {
    0 || 1 => (line: encodeAttempt(attempt), truth: attempt),
    2 => (
      line: jsonEncode(withUnknownFields(json, rand, every: true)),
      truth: attempt,
    ),
    3 => (
      line: jsonEncode({...json}..remove(rand.pick([...json.keys]))),
      truth: null,
    ),
    4 => (
      line: jsonEncode({
        ...json,
        rand.pick([...json.keys]): _wrongType(rand),
      }),
      truth: null,
    ),
    5 => (
      line: jsonEncode({...json, 'timestampUtc': 'yesterday'}),
      truth: null,
    ),
    6 => (
      line: encodeAttempt(attempt).substring(0, rand.between(0, 40)),
      truth: null,
    ),
    _ => (
      line: rand.pick(const ['not json', '[]', '42', 'null', '{}']),
      truth: null,
    ),
  };
});

Object? _wrongType(Rand rand) => rand.pick(const [null, 1.5, <Object?>[], {}]);

Attempt _attempt(Rand rand) => Attempt(
  key: (source: rand.pick(csvSources), id: _lineId(rand)),
  ply: rand.between(0, 60),
  fen: Fen.initial,
  played: rand.pick(const ['e4', 'Nf3', 'O-O', 'exd8=Q+']),
  expected: rand.pick(const ['e4', 'd4', 'c4']),
  correct: rand.nextBool(),
  phase: rand.pick(AttemptPhase.values),
  at: csvTime(rand) ?? DateTime.utc(2026, 9, 22, 12),
);
