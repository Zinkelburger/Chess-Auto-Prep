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

/// A review row as the old app writes it, 11 columns.
String _review(String source, String id, {String name = 'Mainline'}) =>
    '$source,$id,$name,2.50,6.00,2026-09-20T00:00:00.000Z,good,'
    '2026-09-14T00:00:00.000Z,3,1,false';

void main() {
  late Directory documents;
  late TrainingStore store;
  late String kid;
  late String benko;
  late String comma;
  late LineKey mainline;
  late ProgressLoaded admission;

  // These source PGNs stay unchanged while individual cases edit training
  // files. Retain their native admission independently of those row changes.
  ProgressOperation operation() =>
      ProgressOperation(sources: admission.sources);

  File file(String name) => File(p.join(documents.path, name));

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-training-');
    kid = p.join(documents.path, 'repertoires', 'KID', 'Main.pgn');
    benko = p.join(documents.path, 'repertoires', 'Benko', 'Main.pgn');
    comma = p.join(documents.path, 'repertoires', 'Open, Closed', 'Main.pgn');
    mainline = (source: kid, id: 'line_1');
    for (final source in [kid, benko, comma]) {
      await File(source).parent.create(recursive: true);
      await File(source).writeAsString('[Event "Main"]\n\n1. e4 *\n');
    }
    store = TrainingStore(
      documents,
      support: Directory(p.join(documents.path, 'Support')),
    );
    admission = await store.read({kid, benko, comma}) as ProgressLoaded;
  });
  tearDown(() => documents.delete(recursive: true));

  Future<ProgressLoaded> read(Set<String> sources) async =>
      await store.read(sources) as ProgressLoaded;

  test('no files is nothing trained yet', () async {
    final loaded = await read({kid});
    expect(loaded.reviews, isEmpty);
    expect(loaded.streaks, isEmpty);
    expect(loaded.mistakes, isEmpty);
  });

  test('only the rows of the chapters asked for', () async {
    await file(reviewsFile).writeAsString(
      '$reviewsHeader\n${_review(kid, 'line_1')}\n'
      '${_review(benko, 'line_1')}\n',
    );
    final loaded = await read({kid});
    final review = loaded.reviews.values.single;
    expect(review.key, mainline);
    expect((review.ease, review.intervalDays), (2.5, 6.0));
    expect(review.due, DateTime.utc(2026, 9, 20));
    expect((review.lastRating, review.passes, review.fails), ('good', 3, 1));
  });

  test('rows from older versions: 8 and 10 columns, and an unquoted path '
      'with a comma', () async {
    await file(reviewsFile).writeAsString(
      '$reviewsHeader\n'
      '$kid,line_8,Eight,2.50,1.00,,good,\n'
      '$kid,line_10,Ten,2.50,1.00,,good,,2,0\n'
      '$comma,line_c,Comma,2.50,1.00,,good,,1,1,true\n',
    );
    final loaded = await read({kid, comma});
    expect(loaded.reviews.keys, [
      (source: kid, id: 'line_8'),
      (source: kid, id: 'line_10'),
      (source: comma, id: 'line_c'),
    ]);
    expect(loaded.reviews[(source: kid, id: 'line_10')]!.passes, 2);
    expect(loaded.reviews[(source: comma, id: 'line_c')]!.excluded, isTrue);
  });

  test('streaks and the wrong answers in the log', () async {
    await file(
      streaksFile,
    ).writeAsString('$streaksHeader\n$kid,line_1,4,2,0\n$benko,line_1,0,3,1\n');
    await file(attemptsFile).writeAsString(
      '${encodeAttempt(_attempt(mainline, correct: false))}\n'
      '${encodeAttempt(_attempt(mainline, correct: true))}\n'
      'not json\n',
    );
    final loaded = await read({kid});
    expect(loaded.streaks.values.single.streak, 2);
    expect(loaded.mistakes.single.played, 'd4');
  });

  test(
    'same-size external log replacement with restored mtime reloads mistakes',
    () async {
      final text = '${encodeAttempt(_attempt(mainline, correct: false))}\n';
      final log = file(attemptsFile);
      await log.writeAsString(text);
      final timestamp = await log.lastModified();
      expect((await read({kid})).mistakes.single.played, 'd4');
      final replacement = file('replacement.jsonl');
      await replacement.writeAsString(text.replaceAll('d4', 'c4'));
      await replacement.setLastModified(timestamp);
      await replacement.rename(log.path);
      expect((await read({kid})).mistakes.single.played, 'c4');
    },
  );

  test(
    'a linked training participant is unavailable, never followed',
    () async {
      final outside = file('outside.csv');
      await outside.writeAsString(
        '$reviewsHeader\n${_review(kid, 'line_1')}\n',
      );
      await Link(file(reviewsFile).path).create(outside.path);
      expect(await store.read({kid}), isA<ProgressFailed>());
    },
  );

  test('the log read again once it has grown, by either app', () async {
    await file(
      attemptsFile,
    ).writeAsString('${encodeAttempt(_attempt(mainline, correct: false))}\n');
    expect((await read({kid})).mistakes, hasLength(1));
    await store.logAttempt(
      _attempt(mainline, correct: false),
      operation: operation(),
    );
    expect((await read({kid})).mistakes, hasLength(2));
    // The old app's own answer, written behind this store's back.
    await file(attemptsFile).writeAsString(
      '${encodeAttempt(_attempt(mainline, correct: false))}\n',
      mode: FileMode.append,
    );
    expect((await read({kid})).mistakes, hasLength(3));
    expect((await read({benko})).mistakes, isEmpty);
  });

  test('a row that is not one makes the file unreadable, by line', () async {
    await file(reviewsFile).writeAsString(
      '$reviewsHeader\n${_review(kid, 'line_1')}\n$kid,line_2,x,y\n',
    );
    final read = await store.read({kid});
    expect(read, isA<ProgressUnreadable>());
    expect((read as ProgressUnreadable).line, 3);
  });

  test('bytes that are not text make the file unreadable at their line, '
      'and nothing is written over them', () async {
    final bytes = [
      ...utf8.encode('$reviewsHeader\n${_review(kid, 'line_1')}\n'),
      // 0xC3 starts a character and 0x28 is not the rest of one.
      0xC3, 0x28, 0x0A,
    ];
    await file(reviewsFile).writeAsBytes(bytes);
    final read = await store.read({kid});
    expect(read, isA<ProgressUnreadable>());
    expect((read as ProgressUnreadable).file, reviewsFile);
    expect(read.line, 3);
    final written = await store.write(
      operation: operation(),
      reviews: [
        (
          before: null,
          after: Review(key: (source: kid, id: 'line_2'), lineName: 'x'),
        ),
      ],
    );
    expect(written, isA<ProgressUnreadable>());
    expect(await file(reviewsFile).readAsBytes(), bytes);
  });

  Review rated(Review? before) => asWritten(
    (before ?? Review(key: mainline, lineName: 'Mainline')).copyWith(
      intervalDays: 25,
      lastRating: 'good',
      due: DateTime.utc(2026, 10, 15),
    ),
  );

  test('into no files: each with the header the old app writes', () async {
    final written = await store.write(
      operation: operation(),
      reviews: [(before: null, after: rated(null))],
      streaks: [
        (
          before: null,
          after: MoveStreak(key: mainline, ply: 2, streak: 1, learned: false),
        ),
      ],
      history: [_history(mainline)],
    );
    expect(written, isA<ProgressWritten>());
    expect(
      await file(reviewsFile).readAsString(),
      '$reviewsHeader\n$kid,line_1,Mainline,2.50,25.00,'
      '2026-10-15T00:00:00.000Z,good,,0,0,false\n',
    );
    expect(
      await file(streaksFile).readAsString(),
      '$streaksHeader\n$kid,line_1,2,1,0\n',
    );
    expect(
      await file(historyFile).readAsString(),
      '$historyHeader\n$kid,line_1,2026-09-22T12:00:00.000Z,good,0,'
      'trainer\n',
    );
    expect(file('$reviewsFile.pre-csv-v2.bak').existsSync(), isFalse);
  });

  test('replaces the one row and keeps every other byte', () async {
    // A row quoted more than it needs, a CRLF line and another chapter's
    // row: a canonical rewrite would change all three.
    final others =
        '"$benko",line_1,"Benko",2.50,6.00,,good,,3,1,false\r\n'
        '${_review(kid, 'line_2')}\n';
    await file(
      reviewsFile,
    ).writeAsString('$reviewsHeader\n$others${_review(kid, 'line_1')}\n');
    final before = (await read({kid})).reviews[mainline];
    await store.write(
      operation: operation(),
      reviews: [(before: before, after: rated(before))],
    );
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
    final eight = '$benko,line_8,Eight,2.50,1.00,,good,';
    await file(
      reviewsFile,
    ).writeAsString('$eightColumns\n$eight\n${_review(kid, 'line_1')}\n');
    final before = (await read({kid})).reviews[mainline];
    await store.write(
      operation: operation(),
      reviews: [(before: before, after: rated(before))],
    );
    final lines = await file(reviewsFile).readAsLines();
    expect(lines.first, reviewsHeader);
    expect(lines[1], eight, reason: 'an older row keeps its bytes');
    expect((await read({kid, benko})).reviews.length, 2);
  });

  test('keeps what the file held first, once', () async {
    final original = '$reviewsHeader\n${_review(kid, 'line_1')}\n';
    await file(reviewsFile).writeAsString(original);
    final before = (await read({kid})).reviews[mainline];
    await store.write(
      operation: operation(),
      reviews: [(before: before, after: rated(before))],
    );
    await store.write(
      operation: operation(),
      reviews: [(before: rated(before), after: rated(before))],
    );
    expect(await file('$reviewsFile.pre-csv-v2.bak').readAsString(), original);
  });

  test('refuses a row somebody else changed since it was read', () async {
    await file(
      reviewsFile,
    ).writeAsString('$reviewsHeader\n${_review(kid, 'line_1')}\n');
    final before = (await read({kid})).reviews[mainline];
    // The old app rates the same line meanwhile.
    final theirs = _review(kid, 'line_1').replaceFirst(',good,', ',easy,');
    await file(reviewsFile).writeAsString('$reviewsHeader\n$theirs\n');
    final written = await store.write(
      operation: operation(),
      reviews: [(before: before, after: rated(before))],
      history: [_history(mainline)],
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
    ).writeAsString('$reviewsHeader\n${_review(kid, 'line_1')}\n');
    final written = await store.write(
      operation: operation(),
      reviews: [(before: null, after: rated(null))],
    );
    expect(written, isA<ProgressConflict>());
  });

  test('a file it cannot read is left alone, and so are the others', () async {
    await file(streaksFile).writeAsString('$streaksHeader\n"unclosed\n');
    final written = await store.write(
      operation: operation(),
      reviews: [(before: null, after: rated(null))],
      streaks: [
        (
          before: null,
          after: MoveStreak(key: mainline, ply: 0, streak: 1, learned: false),
        ),
      ],
    );
    expect(written, isA<ProgressUnreadable>());
    expect(file(reviewsFile).existsSync(), isFalse);
  });

  test('an answer is appended to the log as it is given', () async {
    await file(attemptsFile).writeAsString('{"old": "row"}');
    await store.logAttempt(
      _attempt(mainline, correct: false),
      operation: operation(),
    );
    final lines = await file(attemptsFile).readAsLines();
    expect(lines.first, '{"old": "row"}');
    expect(jsonDecode(lines.last), {
      'repertoireId': kid,
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
    final answer = utf8.encode(
      encodeAttempt(_attempt(mainline, correct: false)),
    );
    final torn = [...answer, 0x0A, ...answer.sublist(0, 20), 0xC3];
    await file(attemptsFile).writeAsBytes(torn);

    expect(
      await store.logAttempt(
        _attempt(mainline, correct: false),
        operation: operation(),
      ),
      isA<ProgressWritten>(),
    );

    final bytes = await file(attemptsFile).readAsBytes();
    expect(bytes.sublist(0, torn.length), torn);
    expect(
      utf8.decode(bytes.sublist(torn.length)),
      '\n${encodeAttempt(_attempt(mainline, correct: false))}\n',
    );
    // The torn line is passed over; the answers either side of it are not.
    expect((await read({kid})).mistakes, hasLength(2));
  });

  test('waits for the old app holding the Documents folder', () async {
    final old = sqlite3.open(await lockPathOf(documents));
    old.execute('PRAGMA busy_timeout = 0');
    old.execute('BEGIN IMMEDIATE');
    var done = false;
    final logged = store
        .logAttempt(_attempt(mainline, correct: true), operation: operation())
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(done, isFalse);
    old
      ..execute('ROLLBACK')
      ..close();
    expect(await logged, isA<ProgressWritten>());
  });
}

Attempt _attempt(LineKey key, {required bool correct}) => Attempt(
  key: key,
  ply: 0,
  fen: Fen.initial,
  played: correct ? 'e4' : 'd4',
  expected: 'e4',
  correct: correct,
  phase: AttemptPhase.drilling,
  at: DateTime.utc(2026, 9, 22, 12),
);

HistoryRow _history(LineKey key) => HistoryRow(
  key: key,
  at: DateTime.utc(2026, 9, 22, 12),
  rating: 'good',
  mistake: false,
  kind: HistoryKind.trainer,
);
