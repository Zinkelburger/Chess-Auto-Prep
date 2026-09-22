// The training schedule following a chapter that is renamed, moved or
// deleted, against real files in a disposable Documents folder.
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
// Both stores name a failure to touch the disk; here it is always the
// training records' own.
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    hide IoFailure;
import 'package:chess_auto_prep/v2/storage/training_records.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

const _reviews = 'repertoire_reviews.csv';
const _progress = 'repertoire_move_progress.csv';
const _history = 'repertoire_review_history.csv';
const _attempts = 'repertoire_move_attempts.jsonl';

const _reviewsHeader =
    'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
    'last_rating,last_reviewed_utc,pass_count,fail_count,excluded';
const _progressHeader =
    'repertoire_id,line_id,move_index,correct_streak,learned';
const _historyHeader =
    'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';

/// A review row with a name that carries a comma, doubled quotes and a line
/// break, which is what the quoting rules exist for.
String _awkwardReview(String id) =>
    '"$id",line_2,"Benko, ""sharp""\nsidelines",'
    '2.5,6,2026-09-20T00:00:00Z,good,2026-09-14T00:00:00Z,3,1,false';

String _review(String id) =>
    '$id,line_1,Mainline,2.5,6,2026-09-20T00:00:00Z,good,'
    '2026-09-14T00:00:00Z,3,1,false';

String _progressRow(String id) => '$id,line_1,4,2,true';

String _historyRow(String id) =>
    '$id,line_1,2026-09-14T00:00:00Z,good,false,review';

/// A logged answer, spaced the way no encoder would write it, so a line that
/// keeps these bytes proves it was never re-encoded.
String _attemptRow(String id) =>
    '{"repertoireId": "$id", "lineId": "line_1", "moveIndex": 4, '
    '"correct": true, "timestampUtc": "2026-09-14T00:00:00Z"}';

void main() {
  late StoreFixture fixture;
  late TrainingRecords records;
  late DocumentRef kid;
  late DocumentRef benko;

  setUp(() async {
    fixture = await StoreFixture.create();
    records = TrainingRecords(fixture.documents);
    kid = fixture.ref('repertoires/KID/Main.pgn');
    benko = fixture.ref('repertoires/Benko/Main.pgn');
  });
  tearDown(() => fixture.dispose());

  void write(String name, String content) =>
      File(p.join(fixture.documents.path, name)).writeAsStringSync(content);

  String read(String name) =>
      File(p.join(fixture.documents.path, name)).readAsStringSync();

  /// All four files, with one record for each of the two chapters.
  void writeAll() {
    write(_attempts, '${_attemptRow(kid.path)}\n${_attemptRow(benko.path)}\n');
    write(
      _reviews,
      '$_reviewsHeader\n${_review(kid.path)}\n${_awkwardReview(benko.path)}\n',
    );
    write(
      _progress,
      '$_progressHeader\n${_progressRow(kid.path)}\n'
      '${_progressRow(benko.path)}\n',
    );
    write(
      _history,
      '$_historyHeader\n${_historyRow(kid.path)}\n'
      '${_historyRow(benko.path)}\n',
    );
  }

  test('a file nothing matches keeps every one of its bytes', () async {
    writeAll();
    final before = [
      read(_reviews),
      read(_progress),
      read(_history),
      read(_attempts),
    ];
    final result = await records.repoint(
      fixture.ref('repertoires/Slav/Main.pgn'),
      fixture.ref('repertoires/Slav/Renamed.pgn'),
    );
    expect(result, isA<NothingToRepoint>());
    expect([
      read(_reviews),
      read(_progress),
      read(_history),
      read(_attempts),
    ], before);
  });

  test('a quoted, multiline row survives a rewrite of its neighbour', () async {
    writeAll();
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect(await records.repoint(kid, renamed), isA<Repointed>());
    final content = read(_reviews);
    expect(content, startsWith('$_reviewsHeader\n'));
    expect(content, contains(_awkwardReview(benko.path)));
    expect(content, contains('${renamed.path},line_1,Mainline,'));
    expect(content, isNot(contains(kid.path)));
  });

  test('every row of every file that named the chapter moves', () async {
    writeAll();
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect(await records.repoint(kid, renamed), isA<Repointed>());
    expect((await records.repoint(renamed, kid) as Repointed).rowsChanged, 4);
    expect(read(_progress), contains(_progressRow(kid.path)));
    expect(read(_history), contains(_historyRow(kid.path)));
  });

  test('rows inside a folder that moved move with it', () async {
    writeAll();
    final from = fixture.ref('repertoires/KID');
    final to = fixture.ref('repertoires/Kings Indian');
    expect((await records.repoint(from, to) as Repointed).rowsChanged, 4);
    expect(read(_progress), contains(p.join(to.path, 'Main.pgn')));
    expect(read(_history), contains(p.join(to.path, 'Main.pgn')));
    expect(read(_reviews), contains(_awkwardReview(benko.path)));
  });

  test('a file that is not there is not a failure', () async {
    write(_reviews, '$_reviewsHeader\n${_review(kid.path)}\n');
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect((await records.repoint(kid, renamed) as Repointed).rowsChanged, 1);
    expect(
      File(p.join(fixture.documents.path, _history)).existsSync(),
      isFalse,
    );
  });

  test('a record with the wrong number of fields stops everything', () async {
    writeAll();
    final before = [read(_reviews), read(_progress), read(_attempts)];
    write(
      _history,
      '$_historyHeader\n${_historyRow(kid.path)}\n'
      '"${kid.path}",line_1,2026-09-14T00:00:00Z,good,false,review,extra\n',
    );
    final result = await records.repoint(
      kid,
      fixture.ref('repertoires/KID/Classical.pgn'),
    );
    expect(result, isA<Malformed>());
    expect((result as Malformed).file, _history);
    expect(result.line, 3);
    // The other files that would have changed were never written.
    expect([read(_reviews), read(_progress), read(_attempts)], before);
  });

  test('a quoted field nobody closed is malformed, not a guess', () async {
    write(_reviews, '$_reviewsHeader\n"${kid.path},line_1,Mainline\n');
    final before = read(_reviews);
    final result = await records.repoint(
      kid,
      fixture.ref('repertoires/KID/Classical.pgn'),
    );
    expect(result, isA<Malformed>());
    expect(read(_reviews), before);
  });

  test('a file with no header is refused rather than rewritten', () async {
    write(_reviews, '${_review(kid.path)}\n');
    final result = await records.repoint(
      kid,
      fixture.ref('repertoires/KID/Classical.pgn'),
    );
    expect(result, isA<Malformed>());
  });

  test('a pre-quoting path with commas is repaired and moved', () async {
    final comma = fixture.ref('repertoires/KID, Classical/Main.pgn');
    write(_progress, '$_progressHeader\n${_progressRow(comma.path)}\n');
    final renamed = fixture.ref('repertoires/KID Classical/Main.pgn');
    expect((await records.repoint(comma, renamed) as Repointed).rowsChanged, 1);
    expect(
      read(_progress),
      '$_progressHeader\n${_progressRow(renamed.path)}\n',
    );
  });

  test('an 11-column review under an older header moves whole', () async {
    // Rows of each width under the 10-column header of an older version:
    // the row says its own width, as the old app reads it.
    const olderHeader =
        'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
        'last_rating,last_reviewed_utc,pass_count,fail_count';
    final ten =
        '${kid.path},line_10,Ten,2.5,6,2026-09-20T00:00:00Z,good,'
        '2026-09-14T00:00:00Z,3,1';
    write(_reviews, '$olderHeader\n${_review(kid.path)}\n$ten\n');
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect((await records.repoint(kid, renamed) as Repointed).rowsChanged, 2);
    expect(
      read(_reviews),
      '$olderHeader\n${_review(renamed.path)}\n'
      '${ten.replaceFirst(kid.path, renamed.path)}\n',
    );
  });

  test('a quote inside an unquoted path is a character, not a field', () async {
    final quoted = fixture.ref('repertoires/KID/My "best line.pgn');
    write(
      _progress,
      '$_progressHeader\n${_progressRow(quoted.path)}\n'
      '${_progressRow(benko.path)}\n',
    );
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect(
      (await records.repoint(quoted, renamed) as Repointed).rowsChanged,
      1,
    );
    expect(read(_progress), contains(_progressRow(renamed.path)));
    expect(read(_progress), contains(_progressRow(benko.path)));
  });

  test('only the logged answers that named the chapter change', () async {
    writeAll();
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect(await records.repoint(kid, renamed), isA<Repointed>());
    final answers = read(_attempts);
    expect(answers, contains(_attemptRow(benko.path)));
    expect(answers, contains('"repertoireId":"${renamed.path}"'));
    // The rest of the answer is still there, and the log still ends a line.
    expect(answers, contains('"moveIndex":4'));
    expect(answers, contains('"correct":true'));
    expect(answers, isNot(contains(kid.path)));
    expect(answers, endsWith('\n'));
  });

  test('a logged answer that is not a JSON object stops it', () async {
    writeAll();
    write(_attempts, '${read(_attempts)}truncated answer\n');
    final broken = read(_attempts);
    final result = await records.repoint(
      kid,
      fixture.ref('repertoires/KID/Classical.pgn'),
    );
    expect(result, isA<Malformed>());
    expect((result as Malformed).file, _attempts);
    expect(result.line, 3);
    expect(read(_attempts), broken);
    // The CSVs that would have changed were not written either.
    expect(read(_reviews), contains(_review(kid.path)));
  });

  test('what a repoint replaces is kept where the old app keeps it', () async {
    writeAll();
    final before = [read(_reviews), read(_progress), read(_attempts)];
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect(await records.repoint(kid, renamed), isA<Repointed>());
    final operation = Directory(
      p.join(fixture.documents.path, '.cap-reference-history'),
    ).listSync().whereType<Directory>().single;
    String kept(String name) =>
        File(p.join(operation.path, name)).readAsStringSync();
    expect([kept(_reviews), kept(_progress), kept(_attempts)], before);
    expect(
      operation.listSync().map((e) => p.basename(e.path)),
      unorderedEquals([_reviews, _progress, _history, _attempts]),
    );
  });

  test('a rewrite nothing can be kept for does not happen', () async {
    writeAll();
    final before = read(_reviews);
    final history = Directory(
      p.join(fixture.documents.path, '.cap-reference-history'),
    );
    await history.create();
    await Process.run('chmod', ['500', history.path]);
    final result = await records.repoint(
      kid,
      fixture.ref('repertoires/KID/Classical.pgn'),
    );
    await Process.run('chmod', ['u+w', history.path]);
    expect(result, isA<IoFailure>());
    expect(read(_reviews), before);
  }, skip: _needsAPlainUser);

  test('a folder that cannot be written reports the failure', () async {
    writeAll();
    final before = read(_reviews);
    await Process.run('chmod', ['a-w', fixture.documents.path]);
    final result = await records.repoint(
      kid,
      fixture.ref('repertoires/KID/Classical.pgn'),
    );
    await Process.run('chmod', ['u+w', fixture.documents.path]);
    expect(result, isA<IoFailure>());
    expect(read(_reviews), before);
  });

  test('renaming a chapter through the store moves its rows', () async {
    writeAll();
    final revision = await fixture.put(kid, '[Event "KID"]\n\n1. d4 *\n');
    final moved =
        await fixture.store.rename(kid, 'Classical.pgn', expected: revision)
            as Moved;
    expect((moved.training as Repointed).rowsChanged, 4);
    final renamed = fixture.ref('repertoires/KID/Classical.pgn');
    expect(read(_reviews), contains('${renamed.path},line_1,Mainline,'));
    expect(read(_progress), contains(_progressRow(renamed.path)));
    expect(read(_history), contains(_historyRow(renamed.path)));
  });

  test('rows a move could not rewrite are rewritten by the next one', () async {
    writeAll();
    final revision = await fixture.put(kid, '[Event "KID"]\n\n1. d4 *\n');
    // The rename lands and the rows cannot follow, which is what a machine
    // stopping between the two writes would leave behind.
    await Process.run('chmod', ['a-w', fixture.documents.path]);
    final moved =
        await fixture.store.rename(kid, 'Mainline.pgn', expected: revision)
            as Moved;
    await Process.run('chmod', ['u+w', fixture.documents.path]);
    expect(moved.training, isA<IoFailure>());
    expect(read(_progress), contains(_progressRow(kid.path)));

    final renamed = fixture.ref('repertoires/KID/Mainline.pgn');
    final again =
        await fixture.store.rename(
              renamed,
              'Classical.pgn',
              expected: moved.revision,
            )
            as Moved;

    expect(again.training, isA<Repointed>());
    final classical = fixture.ref('repertoires/KID/Classical.pgn');
    expect(read(_progress), contains(_progressRow(classical.path)));
    expect(read(_history), contains(_historyRow(classical.path)));
    expect(read(_progress), isNot(contains(_progressRow(kid.path))));
  }, skip: _needsAPlainUser);

  test('deleting a chapter sends its rows into recovery with it', () async {
    writeAll();
    final revision = await fixture.put(kid, '[Event "KID"]\n\n1. d4 *\n');
    final deleted =
        await fixture.store.delete(kid, expected: revision) as Deleted;
    expect((deleted.training as Repointed).rowsChanged, 4);
    expect(read(_progress), contains(_progressRow(deleted.recoveredTo)));
    // Nothing was dropped: restoring the chapter brings the schedule back.
    expect(
      (await records.repoint(DocumentRef(deleted.recoveredTo), kid)
              as Repointed)
          .rowsChanged,
      4,
    );
    expect(read(_history), contains(_historyRow(kid.path)));
  });
}

final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;
