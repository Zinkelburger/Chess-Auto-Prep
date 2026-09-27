// A chapter renamed or deleted while a training session is writing.
//
// The old app's trainer writes its CSVs under the lock on the folder they
// sit in (`atomic_file.dart` locks the file's parent), which is the
// Documents root — the same lock a v2 move or delete takes. So the two
// serialise: the move waits for the trainer's write, and the row the
// trainer wrote under the old path is repointed with the rest.
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/lock_path.dart';
import 'store_fixture.dart';

const _reviews = 'repertoire_reviews.csv';
const _header =
    'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
    'last_result,last_reviewed_utc,repetitions,lapses,suspended';

String _review(String id, String line) =>
    '$id,$line,Mainline,2.5,6,2026-09-20T00:00:00Z,good,'
    '2026-09-14T00:00:00Z,3,1,false';

void main() {
  late StoreFixture fixture;
  late DocumentRef ref;
  late Revision revision;
  late File reviews;

  setUp(() async {
    fixture = await StoreFixture.create();
    ref = fixture.ref('repertoires/KID/Main.pgn');
    revision = await fixture.put(ref, '[Event "Main"]\n\n1. d4 *\n');
    reviews = File(p.join(fixture.documents.path, _reviews));
    await reviews.writeAsString('$_header\n${_review(ref.path, 'line_1')}\n');
  });
  tearDown(() => fixture.dispose());

  /// The trainer, holding the Documents folder the way the old app holds it
  /// while it writes a CSV there.
  Future<Database> trainerWriting() async {
    final trainer = sqlite3.open(await lockPathOf(fixture.documents));
    trainer.execute('PRAGMA busy_timeout = 0');
    trainer.execute('BEGIN IMMEDIATE');
    return trainer;
  }

  /// The trainer's write: one more review row naming the chapter's path as
  /// the trainer still knows it.
  Future<void> trainerWrote(Database trainer) async {
    await reviews.writeAsString(
      '${_review(ref.path, 'line_2')}\n',
      mode: FileMode.append,
    );
    trainer.execute('ROLLBACK');
    trainer.close();
  }

  test(
    'a rename waits for the trainer, then repoints the row it wrote',
    () async {
      final trainer = await trainerWriting();
      var done = false;
      final renamed = fixture.store
          .rename(ref, 'Mainline.pgn', expected: revision)
          .whenComplete(() => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(done, isFalse, reason: 'the trainer still holds the folder');
      await trainerWrote(trainer);
      final result = await renamed;
      expect(result, isA<Moved>());
      expect((result as Moved).training, isA<Repointed>());
      expect((result.training as Repointed).rowsChanged, 2);
      final text = await reviews.readAsString();
      expect(text, isNot(contains(ref.path)));
      final moved = fixture.ref('repertoires/KID/Mainline.pgn').path;
      expect(moved.allMatches(text), hasLength(2));
      expect(text, contains('line_2'), reason: 'the late row is kept');
    },
  );

  test('a delete waits for the trainer, and the row it wrote follows the '
      'chapter into recovery', () async {
    final trainer = await trainerWriting();
    var done = false;
    final deleted = fixture.store
        .delete(ref, expected: revision)
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse);
    await trainerWrote(trainer);
    final result = await deleted;
    expect(result, isA<Deleted>());
    final recoveredTo = (result as Deleted).recoveredTo;
    expect((result.training as Repointed).rowsChanged, 2);
    final text = await reviews.readAsString();
    expect(text, isNot(contains(ref.path)));
    expect(recoveredTo.allMatches(text), hasLength(2));
  });

  test('a row the trainer writes after the move already names the moved '
      'file, so nothing is repointed twice', () async {
    final result = await fixture.store.rename(
      ref,
      'Mainline.pgn',
      expected: revision,
    );
    final moved = fixture.ref('repertoires/KID/Mainline.pgn');
    expect(((result as Moved).training as Repointed).rowsChanged, 1);
    await reviews.writeAsString(
      '${_review(moved.path, 'line_2')}\n',
      mode: FileMode.append,
    );
    final text = await reviews.readAsString();
    expect(moved.path.allMatches(text), hasLength(2));
    expect(text, isNot(contains(ref.path)));
  });
}
