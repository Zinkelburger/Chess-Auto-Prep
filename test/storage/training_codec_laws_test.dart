// Laws of the training files over generated text: the records a reader
// finds are the text cut into pieces, nothing added and nothing lost; a row
// as written reads back as itself, with the same values, and the
// old app's rows of every width read as what they hold; an answer line is
// read or passed over, never thrown on; and a write through the store
// changes only the rows it names, down to the byte.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/gen/csv_gen.dart';
import '../support/props.dart';

void main() {
  _recordLaws();
  _rowLaws();
  _frameLaw();
}

void _recordLaws() {
  forAll('the records are the text, cut where the truth says', reviewCsvs, (
    csv,
  ) {
    final read = readCsvRecords(csv.text);
    if (csv.unclosedLine case final line?) {
      expect(read, isA<CsvUnreadable>());
      expect((read as CsvUnreadable).line, line);
      return;
    }
    if (read is! CsvParsed) fail('unreadable: $read');
    expect(_joined(read.records), csv.text);
    expect(
      [
        for (final r in read.records)
          [r.source, r.terminator, r.line, r.fields],
      ],
      [
        for (final r in csv.records) [r.source, r.terminator, r.line, r.fields],
      ],
    );
  });

  forAll(
    'damaged text is read as pieces of itself or refused, never thrown on',
    reviewCsvs,
    (csv) {
      final rand = Rand(csv.text.length);
      var text = csv.text;
      for (var i = rand.between(1, 4); i > 0; i--) {
        final at = rand.nextInt(text.length + 1);
        text = text.replaceRange(
          at,
          at,
          rand.pick(const ['"', ',', '\r', '\n', '""', ' ']),
        );
      }
      if (readCsvRecords(text) case CsvParsed(:final records)) {
        expect(_joined(records), text);
      }
    },
  );
}

String _joined(List<CsvRecord> records) =>
    records.map((r) => '${r.source}${r.terminator}').join();

const Generator<Review> _reviews = Generator(csvReview);

/// A review as the old app writes it, [width] columns wide, spelled one of
/// the ways a file holds it.
typedef _OldRow = ({Review review, int width, RowSpelling spelling});

final Generator<_OldRow> _oldRows = Generator((rand) {
  final review = csvReview(rand);
  final width = rand.pick(const [8, 10, 11]);
  final cells = reviewCells(review, width);
  final spellings = [
    RowSpelling.canonical,
    RowSpelling.quoted,
    if (legacyWritable(cells)) RowSpelling.legacy,
  ];
  return (review: review, width: width, spelling: rand.pick(spellings));
});

void _rowLaws() {
  forAll(
    'a review as written reads back as itself, with the same values',
    _reviews,
    (review) {
      final written = asWritten(review);
      expect(encodeReview(asWritten(written)), encodeReview(written));
      final row = encodeCsvRecord(encodeReview(review));
      final read = readCsvRecords(row) as CsvParsed;
      expect(read.records.single.fields, encodeReview(review));
      expect(
        encodeReview(decodeReview(read.records.single.fields)!),
        encodeReview(written),
      );
    },
  );

  forAll(
    'the old app\'s rows of 8, 10 and 11 columns read as what they hold',
    _oldRows,
    (old) {
      final cells = reviewCells(old.review, old.width);
      final row = switch (old.spelling) {
        RowSpelling.canonical => encodeCsvRecord(cells),
        _ => spelledRow(cells, old.spelling).source,
      };
      final header = reviewsHeader.split(',').take(old.width).join(',');
      final records = (readCsvRecords('$header\n$row\n') as CsvParsed).records;
      final record = records[1];
      final width = rowWidth(reviewsFile, record, headerWidth(records));
      final read = decodeReview(dataCells(record, width)!);
      final truth = reviewAtWidth(old.review, old.width);
      expect(encodeReview(read!), encodeReview(truth));
    },
  );

  forAll(
    'an answer line is read, with fields it does not know passed over, '
    'or passed over itself; never thrown on',
    attemptLines,
    (line) {
      final read = decodeAttempt(line.line);
      expect(
        read == null ? null : encodeAttempt(read),
        line.truth == null ? null : encodeAttempt(line.truth!),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// The frame law, through the store
// ---------------------------------------------------------------------------

/// Stands for the chapter's real path, which only exists once a case has
/// its own folder.
const _chapter = '@CHAPTER@';
const _line = 'line_t';
const _ply = 3;

/// A review file and a streak file around one line's rows, which may or may
/// not be there yet, and the change a write makes to them.
final class _Frame {
  _Frame({
    required this.reviews,
    required this.streaks,
    required this.reviewAt,
    required this.streakAt,
    required this.bom,
    required this.seed,
  });

  final GeneratedCsv reviews;
  final GeneratedCsv streaks;

  /// Which record holds the line's review, or its streak; null when none.
  final int? reviewAt;
  final int? streakAt;
  final bool bom;
  final int seed;

  @override
  String toString() =>
      '_Frame(bom: $bom, reviewAt: $reviewAt, streakAt: $streakAt, '
      'seed: $seed)\nreviews: $reviews\nstreaks: $streaks';
}

final Generator<_Frame> _frames = Generator((rand) {
  final (reviews, reviewAt) = _file(
    rand,
    reviewsHeader.split(',').take(rand.pick(const [11, 11, 10, 8])).toList(),
    () {
      final width = rand.pick(const [11, 10, 8]);
      return reviewCells(csvReview(rand), width);
    },
    reviewCells(csvReview(rand, key: (source: _chapter, id: _line)), 11),
  );
  final (streaks, streakAt) = _file(
    rand,
    streaksHeader.split(','),
    () => encodeStreak(csvStreak(rand)),
    encodeStreak(
      csvStreak(rand, key: (source: _chapter, id: _line), ply: _ply),
    ),
  );
  return _Frame(
    reviews: reviews,
    streaks: streaks,
    reviewAt: reviewAt,
    streakAt: streakAt,
    bom: rand.chance(30),
    seed: rand.between(0, 1 << 30),
  );
});

/// A file under [header] of other lines' rows from [other] and filler, with
/// [mine] among them half the time, and where it went.
(GeneratedCsv, int?) _file(
  Rand rand,
  List<String> header,
  List<String> Function() other,
  List<String> mine,
) {
  String spelled(List<String> cells) {
    final spelling = rand.pick(RowSpelling.values);
    return spelling == RowSpelling.legacy && !legacyWritable(cells)
        ? encodeCsvRecord(cells)
        : spelledRow(cells, spelling).source;
  }

  final rows = [
    for (var i = rand.between(0, 6); i > 0; i--)
      rand.chance(25) ? csvFiller(rand).source : spelled(other()),
  ];
  final at = rand.nextBool() ? rand.between(0, rows.length) : null;
  if (at != null) rows.insert(at, spelled(mine));
  // The fields are not this law's business: the record law checks them.
  final csv = csvOf(rand, [
    (source: header.join(','), fields: header),
    for (final row in rows) (source: row, fields: const <String>[]),
  ], finalNewline: rand.chance(70));
  return (csv, at == null ? null : at + 1);
}

void _frameLaw() {
  forAllAsync(
    'a write changes only the rows it names: every other record '
    'keeps its bytes, the byte-order mark and its line ending',
    _frames,
    (frame) async {
      final documents = await Directory.systemTemp.createTemp('training-laws-');
      try {
        await _checkFrame(documents, frame);
      } finally {
        await documents.delete(recursive: true);
      }
    },
    runs: 40,
  );
}

Future<void> _checkFrame(Directory documents, _Frame frame) async {
  final chapter = p.join(documents.path, 'repertoires', 'KID', 'Main.pgn');
  await File(chapter).create(recursive: true);
  await File(chapter).writeAsString('[Event "Main"]\n\n1. e4 *\n');
  String text(GeneratedCsv csv) => csv.text.replaceAll(_chapter, chapter);
  File file(String name) => File(p.join(documents.path, name));
  final mark = frame.bom ? '\ufeff' : '';
  await file(reviewsFile).writeAsString('$mark${text(frame.reviews)}');
  await file(streaksFile).writeAsString('$mark${text(frame.streaks)}');
  final store = TrainingStore(
    documents,
    support: Directory(p.join(documents.path, 'Support')),
  );
  final loaded = await store.read({chapter});
  if (loaded is! ProgressLoaded) fail('unreadable: $loaded');
  final key = (source: chapter, id: _line);
  final rand = Rand(frame.seed);
  final review = asWritten(csvReview(rand, key: key));
  final streak = csvStreak(rand, key: key, ply: _ply);
  final written = await store.write(
    operation: ProgressOperation(sources: loaded.sources),
    reviews: [(before: loaded.reviews[key], after: review)],
    streaks: [(before: loaded.streaks[(line: key, ply: _ply)], after: streak)],
  );
  expect(written, isA<ProgressWritten>());
  await _expectFrame(
    file(reviewsFile),
    text(frame.reviews),
    frame.bom,
    reviewsHeader,
    frame.reviewAt,
    encodeCsvRecord(encodeReview(review)),
  );
  await _expectFrame(
    file(streaksFile),
    text(frame.streaks),
    frame.bom,
    streaksHeader,
    frame.streakAt,
    encodeCsvRecord(encodeStreak(streak)),
  );
}

/// Fails unless [file] holds [before] with its header brought up to
/// [header], the record at [at] replaced by [row] — or [row] added after
/// the last record when there is none — and every other record's bytes,
/// line ending and the byte-order mark as they were.
Future<void> _expectFrame(
  File file,
  String before,
  bool bom,
  String header,
  int? at,
  String row,
) async {
  final bytes = await file.readAsBytes();
  final marked =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  expect(marked, bom, reason: 'the byte-order mark');
  final after = utf8.decode(bytes.sublist(marked ? 3 : 0));
  final was = (readCsvRecords(before) as CsvParsed).records;
  final expected = [
    for (final (i, r) in was.indexed)
      (
        i == 0 ? header : (i == at ? row : r.source),
        i == was.length - 1 && at == null && r.terminator.isEmpty
            ? '\n'
            : r.terminator,
      ),
    if (at == null) (row, '\n'),
  ];
  final now = (readCsvRecords(after) as CsvParsed).records;
  expect([for (final r in now) (r.source, r.terminator)], expected);
}
