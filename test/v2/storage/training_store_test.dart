// Training progress read and written against real files in a disposable
// Documents folder, in the old app's formats, beside rows the old app wrote.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/lock_path.dart';

const _kid = '/home/me/Documents/repertoires/KID/Main.pgn';
const _benko = '/home/me/Documents/repertoires/Benko/Main.pgn';
const _mainline = (source: _kid, id: 'line_1');

/// A review row as the old app writes it, 11 columns.
String _review(String source, String id, {String name = 'Mainline'}) =>
    '$source,$id,$name,2.50,6.00,2026-09-20T00:00:00.000Z,good,'
    '2026-09-14T00:00:00.000Z,3,1,false';

void main() {
  late Directory documents;
  late TrainingStore store;

  File file(String name) => File(p.join(documents.path, name));

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-training-');
    store = TrainingStore(
      documents,
      support: Directory(p.join(documents.path, 'Support')),
    );
  });
  tearDown(() => documents.delete(recursive: true));

  Future<ProgressLoaded> read(Set<String> sources) async =>
      await store.read(sources) as ProgressLoaded;

  test('no files is nothing trained yet', () async {
    final loaded = await read({_kid});
    expect(loaded.reviews, isEmpty);
    expect(loaded.streaks, isEmpty);
    expect(loaded.mistakes, isEmpty);
  });

  test('only the rows of the chapters asked for', () async {
    await file(reviewsFile).writeAsString(
      '$reviewsHeader\n${_review(_kid, 'line_1')}\n'
      '${_review(_benko, 'line_1')}\n',
    );
    final loaded = await read({_kid});
    final review = loaded.reviews.values.single;
    expect(review.key, _mainline);
    expect((review.ease, review.intervalDays), (2.5, 6.0));
    expect(review.due, DateTime.utc(2026, 9, 20));
    expect((review.lastRating, review.passes, review.fails), ('good', 3, 1));
  });

  test('rows from older versions: 8 and 10 columns, and an unquoted path '
      'with a comma', () async {
    const comma = '/home/me/Documents/repertoires/Open, Closed/Main.pgn';
    await file(reviewsFile).writeAsString(
      '$reviewsHeader\n'
      '$_kid,line_8,Eight,2.50,1.00,,good,\n'
      '$_kid,line_10,Ten,2.50,1.00,,good,,2,0\n'
      '$comma,line_c,Comma,2.50,1.00,,good,,1,1,true\n',
    );
    final loaded = await read({_kid, comma});
    expect(loaded.reviews.keys, [
      (source: _kid, id: 'line_8'),
      (source: _kid, id: 'line_10'),
      (source: comma, id: 'line_c'),
    ]);
    expect(loaded.reviews[(source: _kid, id: 'line_10')]!.passes, 2);
    expect(loaded.reviews[(source: comma, id: 'line_c')]!.excluded, isTrue);
  });

  test('streaks and the wrong answers in the log', () async {
    await file(streaksFile).writeAsString(
      '$streaksHeader\n$_kid,line_1,4,2,0\n$_benko,line_1,0,3,1\n',
    );
    await file(attemptsFile).writeAsString(
      '${encodeAttempt(_attempt(correct: false))}\n'
      '${encodeAttempt(_attempt(correct: true))}\n'
      'not json\n',
    );
    final loaded = await read({_kid});
    expect(loaded.streaks.values.single.streak, 2);
    expect(loaded.mistakes.single.played, 'd4');
  });

  test('the log read again once it has grown, by either app', () async {
    await file(
      attemptsFile,
    ).writeAsString('${encodeAttempt(_attempt(correct: false))}\n');
    expect((await read({_kid})).mistakes, hasLength(1));
    await store.logAttempt(_attempt(correct: false));
    expect((await read({_kid})).mistakes, hasLength(2));
    // The old app's own answer, written behind this store's back.
    await file(attemptsFile).writeAsString(
      '${encodeAttempt(_attempt(correct: false))}\n',
      mode: FileMode.append,
    );
    expect((await read({_kid})).mistakes, hasLength(3));
    expect((await read({_benko})).mistakes, isEmpty);
  });

  test('a row that is not one makes the file unreadable, by line', () async {
    await file(reviewsFile).writeAsString(
      '$reviewsHeader\n${_review(_kid, 'line_1')}\n$_kid,line_2,x,y\n',
    );
    final read = await store.read({_kid});
    expect(read, isA<ProgressUnreadable>());
    expect((read as ProgressUnreadable).line, 3);
  });

  test('bytes that are not text make the file unreadable at their line, '
      'and nothing is written over them', () async {
    final bytes = [
      ...utf8.encode('$reviewsHeader\n${_review(_kid, 'line_1')}\n'),
      // 0xC3 starts a character and 0x28 is not the rest of one.
      0xC3, 0x28, 0x0A,
    ];
    await file(reviewsFile).writeAsBytes(bytes);
    final read = await store.read({_kid});
    expect(read, isA<ProgressUnreadable>());
    expect((read as ProgressUnreadable).file, reviewsFile);
    expect(read.line, 3);
    final written = await store.write(
      reviews: [
        (
          before: null,
          after: const Review(key: (source: _kid, id: 'line_2'), lineName: 'x'),
        ),
      ],
    );
    expect(written, isA<ProgressUnreadable>());
    expect(await file(reviewsFile).readAsBytes(), bytes);
  });

  Review rated(Review? before) => asWritten(
    (before ?? const Review(key: _mainline, lineName: 'Mainline')).copyWith(
      intervalDays: 25,
      lastRating: 'good',
      due: DateTime.utc(2026, 10, 15),
    ),
  );

  test('into no files: each with the header the old app writes', () async {
    final written = await store.write(
      reviews: [(before: null, after: rated(null))],
      streaks: [
        (
          before: null,
          after: const MoveStreak(
            key: _mainline,
            ply: 2,
            streak: 1,
            learned: false,
          ),
        ),
      ],
      history: [_history()],
    );
    expect(written, isA<ProgressWritten>());
    expect(
      await file(reviewsFile).readAsString(),
      '$reviewsHeader\n$_kid,line_1,Mainline,2.50,25.00,'
      '2026-10-15T00:00:00.000Z,good,,0,0,false\n',
    );
    expect(
      await file(streaksFile).readAsString(),
      '$streaksHeader\n$_kid,line_1,2,1,0\n',
    );
    expect(
      await file(historyFile).readAsString(),
      '$historyHeader\n$_kid,line_1,2026-09-22T12:00:00.000Z,good,0,'
      'trainer\n',
    );
    expect(file('$reviewsFile.pre-csv-v2.bak').existsSync(), isFalse);
  });

  test('replaces the one row and keeps every other byte', () async {
    // A row quoted more than it needs, a CRLF line and another chapter's
    // row: a canonical rewrite would change all three.
    final others =
        '"$_benko",line_1,"Benko",2.50,6.00,,good,,3,1,false\r\n'
        '${_review(_kid, 'line_2')}\n';
    await file(
      reviewsFile,
    ).writeAsString('$reviewsHeader\n$others${_review(_kid, 'line_1')}\n');
    final before = (await read({_kid})).reviews[_mainline];
    await store.write(reviews: [(before: before, after: rated(before))]);
    final text = await file(reviewsFile).readAsString();
    expect(text, startsWith('$reviewsHeader\n$others'));
    expect(
      text,
      endsWith(
        ',25.00,2026-10-15T00:00:00.000Z,good,'
        '2026-09-14T00:00:00.000Z,3,1,false\n',
      ),
    );
  });

  test('a write under an older header writes the current one', () async {
    const eightColumns =
        'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
        'last_rating,last_reviewed_utc';
    const eight = '$_benko,line_8,Eight,2.50,1.00,,good,';
    await file(
      reviewsFile,
    ).writeAsString('$eightColumns\n$eight\n${_review(_kid, 'line_1')}\n');
    final before = (await read({_kid})).reviews[_mainline];
    await store.write(reviews: [(before: before, after: rated(before))]);
    final lines = await file(reviewsFile).readAsLines();
    expect(lines.first, reviewsHeader);
    expect(lines[1], eight, reason: 'an older row keeps its bytes');
    expect((await read({_kid, _benko})).reviews.length, 2);
  });

  test('keeps what the file held first, once', () async {
    final original = '$reviewsHeader\n${_review(_kid, 'line_1')}\n';
    await file(reviewsFile).writeAsString(original);
    final before = (await read({_kid})).reviews[_mainline];
    await store.write(reviews: [(before: before, after: rated(before))]);
    await store.write(reviews: [(before: rated(before), after: rated(before))]);
    expect(await file('$reviewsFile.pre-csv-v2.bak').readAsString(), original);
  });

  test('refuses a row somebody else changed since it was read', () async {
    await file(
      reviewsFile,
    ).writeAsString('$reviewsHeader\n${_review(_kid, 'line_1')}\n');
    final before = (await read({_kid})).reviews[_mainline];
    // The old app rates the same line meanwhile.
    final theirs = _review(_kid, 'line_1').replaceFirst(',good,', ',easy,');
    await file(reviewsFile).writeAsString('$reviewsHeader\n$theirs\n');
    final written = await store.write(
      reviews: [(before: before, after: rated(before))],
      history: [_history()],
    );
    expect(written, isA<ProgressConflict>());
    expect(await file(reviewsFile).readAsString(), contains(',easy,'));
    expect(
      file(historyFile).existsSync(),
      isFalse,
      reason: 'nothing of a refused write lands',
    );
  });

  test('refuses to add a row somebody else added first', () async {
    await file(
      reviewsFile,
    ).writeAsString('$reviewsHeader\n${_review(_kid, 'line_1')}\n');
    final written = await store.write(
      reviews: [(before: null, after: rated(null))],
    );
    expect(written, isA<ProgressConflict>());
  });

  test('a file it cannot read is left alone, and so are the others', () async {
    await file(streaksFile).writeAsString('$streaksHeader\n"unclosed\n');
    final written = await store.write(
      reviews: [(before: null, after: rated(null))],
      streaks: [
        (
          before: null,
          after: const MoveStreak(
            key: _mainline,
            ply: 0,
            streak: 1,
            learned: false,
          ),
        ),
      ],
    );
    expect(written, isA<ProgressUnreadable>());
    expect(file(reviewsFile).existsSync(), isFalse);
  });

  test('an answer is appended to the log as it is given', () async {
    await file(attemptsFile).writeAsString('{"old": "row"}');
    await store.logAttempt(_attempt(correct: false));
    final lines = await file(attemptsFile).readAsLines();
    expect(lines.first, '{"old": "row"}');
    expect(jsonDecode(lines.last), {
      'repertoireId': _kid,
      'lineId': 'line_1',
      'moveIndex': 0,
      'fen': Fen.initial.value,
      'playedSan': 'd4',
      'expectedSan': 'e4',
      'correct': false,
      'phase': 'drilling',
      'timestampUtc': '2026-09-22T12:00:00.000Z',
    });
  });

  test('an answer goes after a torn line, whose bytes are kept', () async {
    // An answer, then another cut short inside a character: bytes that are
    // not text.
    final answer = utf8.encode(encodeAttempt(_attempt(correct: false)));
    final torn = [...answer, 0x0A, ...answer.sublist(0, 20), 0xC3];
    await file(attemptsFile).writeAsBytes(torn);

    expect(
      await store.logAttempt(_attempt(correct: false)),
      isA<ProgressWritten>(),
    );

    final bytes = await file(attemptsFile).readAsBytes();
    expect(bytes.sublist(0, torn.length), torn);
    expect(
      utf8.decode(bytes.sublist(torn.length)),
      '\n${encodeAttempt(_attempt(correct: false))}\n',
    );
    // The torn line is passed over; the answers either side of it are not.
    expect((await read({_kid})).mistakes, hasLength(2));
  });

  test('waits for the old app holding the Documents folder', () async {
    final old = sqlite3.open(await lockPathOf(documents));
    old.execute('PRAGMA busy_timeout = 0');
    old.execute('BEGIN IMMEDIATE');
    var done = false;
    final logged = store
        .logAttempt(_attempt(correct: true))
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(done, isFalse);
    old
      ..execute('ROLLBACK')
      ..close();
    expect(await logged, isA<ProgressWritten>());
  });
}

Attempt _attempt({required bool correct}) => Attempt(
  key: _mainline,
  ply: 0,
  fen: Fen.initial,
  played: correct ? 'e4' : 'd4',
  expected: 'e4',
  correct: correct,
  phase: AttemptPhase.drilling,
  at: DateTime.utc(2026, 9, 22, 12),
);

HistoryRow _history() => HistoryRow(
  key: _mainline,
  at: DateTime.utc(2026, 9, 22, 12),
  rating: 'good',
  mistake: false,
  kind: HistoryKind.trainer,
);
