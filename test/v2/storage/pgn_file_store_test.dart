// Real files in a disposable directory: the store is the filesystem, so
// there is nothing here to fake.
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('a created document reads back as it was written', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final created = await fixture.store.create(ref, '1. d4 Nf6 *\n');
    expect(created, isA<Created>());
    final opened = await fixture.store.open(ref);
    expect((opened as Opened).text, '1. d4 Nf6 *\n');
    expect(opened.revision, (created as Created).revision);
  });

  test('a document that is not there is absent, not empty', () async {
    expect(
      await fixture.store.open(fixture.ref('KID/Gone.pgn')),
      isA<Absent>(),
    );
  });

  test('create refuses a name that is taken and keeps it', () async {
    final ref = fixture.ref('KID/Main.pgn');
    await fixture.store.create(ref, 'first *\n');
    expect(await fixture.store.create(ref, 'second *\n'), isA<Collision>());
    expect(await File(ref.path).readAsString(), 'first *\n');
  });

  test('a save with the loaded revision commits and hands back what it '
      'replaced', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'before *\n');
    final saved = await fixture.store.save(
      ref,
      'after *\n',
      expected: revision,
    );
    final receipt = (saved as Saved).receipt;
    expect(receipt.before, 'before *\n');
    expect(receipt.beforeRevision, revision);
    expect(receipt.committed, isNot(revision));
    expect(await File(ref.path).readAsString(), 'after *\n');
    expect(
      (await fixture.store.open(ref) as Opened).revision,
      receipt.committed,
    );
  });

  test('saving the same text again changes nothing', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'same *\n');
    final saved = await fixture.store.save(ref, 'same *\n', expected: revision);
    expect((saved as Saved).receipt.committed, revision);
    expect(fixture.keptVersions(ref), isEmpty);
  });

  test('a save against a revision the file no longer has is a conflict, and '
      'the file keeps what is on disk', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'mine *\n');
    await File(ref.path).writeAsString('theirs *\n');
    final result = await fixture.store.save(
      ref,
      'draft *\n',
      expected: revision,
    );
    final current = (result as Conflict).current;
    expect(current, isNotNull);
    expect(current, isNot(revision));
    expect(await File(ref.path).readAsString(), 'theirs *\n');
  });

  test('a save on a document that was deleted is a conflict with nothing to '
      'compare against', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'mine *\n');
    await File(ref.path).delete();
    final result = await fixture.store.save(
      ref,
      'draft *\n',
      expected: revision,
    );
    expect((result as Conflict).current, isNull);
  });

  test('rename keeps the document and its revision', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'moves *\n');
    final moved = await fixture.store.rename(
      ref,
      'Mainline.pgn',
      expected: revision,
    );
    expect((moved as Moved).revision, revision);
    expect(await File(ref.path).exists(), isFalse);
    final renamed = fixture.ref('KID/Mainline.pgn');
    expect((await fixture.store.open(renamed) as Opened).text, 'moves *\n');
  });

  test('rename onto a taken name collides and moves nothing', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'moves *\n');
    await fixture.put(fixture.ref('KID/Other.pgn'), 'other *\n');
    expect(
      await fixture.store.rename(ref, 'Other.pgn', expected: revision),
      isA<Collision>(),
    );
    expect(await File(ref.path).readAsString(), 'moves *\n');
    expect(
      await File(fixture.ref('KID/Other.pgn').path).readAsString(),
      'other *\n',
    );
  });

  test('move puts a document in another repertoire', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'moves *\n');
    final destination = fixture.ref('Benko/Main.pgn');
    expect(
      await fixture.store.move(ref, destination, expected: revision),
      isA<Moved>(),
    );
    expect((await fixture.store.open(destination) as Opened).text, 'moves *\n');
  });

  test('a move against a stale revision is a conflict', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'moves *\n');
    await File(ref.path).writeAsString('changed *\n');
    expect(
      await fixture.store.move(
        ref,
        fixture.ref('Benko/Main.pgn'),
        expected: revision,
      ),
      isA<Conflict>(),
    );
    expect(await File(ref.path).exists(), isTrue);
  });

  test(
    'a deleted document moves into the recovery folder the old app uses',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, 'moves *\n');
      final deleted = await fixture.store.delete(ref, expected: revision);
      final recovered = File((deleted as Deleted).recoveredTo);
      expect(p.basename(recovered.parent.path), '.cap-pgn-history');
      expect(p.basename(recovered.path), endsWith('-Main.pgn'));
      expect(await recovered.readAsString(), 'moves *\n');
      expect(await fixture.store.open(ref), isA<Absent>());
    },
  );

  test('a delete against a stale revision keeps the document', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'moves *\n');
    await File(ref.path).writeAsString('changed *\n');
    expect(
      await fixture.store.delete(ref, expected: revision),
      isA<Conflict>(),
    );
    expect(await File(ref.path).readAsString(), 'changed *\n');
  });

  test('a path outside the documents folder is refused', () async {
    final outside = DocumentRef(p.join(fixture.root.path, 'elsewhere.pgn'));
    expect(await fixture.store.create(outside, 'x *\n'), isA<IoFailure>());
    expect(await File(outside.path).exists(), isFalse);
  });

  test('a refused path leaves no folders behind outside the root', () async {
    final outside = DocumentRef(
      p.join(fixture.root.path, 'Elsewhere', 'Deeper', 'x.pgn'),
    );
    expect(await fixture.store.create(outside, 'x *\n'), isA<IoFailure>());
    expect(
      await Directory(p.join(fixture.root.path, 'Elsewhere')).exists(),
      isFalse,
    );
  });
}
