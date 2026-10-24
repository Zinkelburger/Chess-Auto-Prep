// A chapter renamed or deleted while a training session is writing.
//
// The trainer of another copy of the app writes its CSVs under the lock on
// the folder they sit in, which is the Documents root — the same lock a move
// or delete takes. So the two serialise: the move waits for the trainer's write, and
// the row the trainer wrote under the old path is repointed with the rest.
import 'dart:io';

import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/training_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/other_copy_lock.dart';
import 'store_fixture.dart';

String _review(String id, String line) =>
    '$id,$line,Mainline,2.50,6.00,2026-09-20T00:00:00.000Z,good,'
    '2026-09-14T00:00:00.000Z,3,1,false';

void main() {
  late StoreFixture fixture;
  late DocumentRef ref;
  late Revision revision;
  late File reviews;

  setUp(() async {
    fixture = await StoreFixture.create();
    ref = fixture.ref('repertoires/KID/Main.pgn');
    revision = await fixture.put(ref, '[Event "Main"]\n\n1. d4 *\n');
    reviews = File(p.join(fixture.documents.path, reviewsFile));
    await reviews.writeAsString(
      '$reviewsHeader\n${_review(ref.path, 'line_1')}\n',
    );
  });
  tearDown(() => fixture.dispose());

  /// The trainer, holding the Documents folder while it writes a CSV
  /// there.
  Future<Future<void> Function()> trainerWriting() =>
      holdLockElsewhere(fixture.documents);

  /// The trainer's write: one more review row naming the chapter's path as
  /// the trainer still knows it.
  Future<void> trainerWrote(Future<void> Function() release) async {
    await reviews.writeAsString(
      '${_review(ref.path, 'line_2')}\n',
      mode: FileMode.append,
    );
    await release();
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
