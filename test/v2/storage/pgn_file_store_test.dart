// Real files in a disposable directory: the store is the filesystem, so
// there is nothing here to fake.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_lock.dart';
import 'package:chess_auto_prep/v2/storage/mutation_guards.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  // One-game chapters, so a save can say which game it is editing.
  final mine = oneGame('1. d4');
  final draft = oneGame('1. d4 Nf6');
  final theirs = oneGame('1. e4');

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

  test('a large chapter is opened, saved and kept like a small one', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final games = [for (var i = 1; i <= 3000; i++) gameOf(i, '1. d4 d5')];
    final text = chapterOf(games);
    expect(text.length, greaterThan(64 * 1024));
    final created = await fixture.store.create(ref, text) as Created;
    final opened = await fixture.store.open(ref) as Opened;
    expect(opened.text, text);
    expect(opened.revision, created.revision);
    final edited = chapterOf([gameOf(1, '1. d4 Nf6'), ...games.skip(1)]);
    final saved = await fixture.edit(ref, edited, opened.revision) as Saved;
    expect(saved.receipt.before, text);
    expect(await File(ref.path).readAsString(), edited);
    expect(
      (await fixture.store.open(ref) as Opened).revision,
      saved.receipt.committed,
    );
    expect(fixture.keptTexts(ref), [text]);
  });

  test(
    'a Latin-1 PGN opens with its accents and will not be written back',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      const text = '[White "Réti"]\n\n1. Nf3 *\n';
      await Directory(p.dirname(ref.path)).create(recursive: true);
      await File(ref.path).writeAsBytes(latin1.encode(text));
      final opened = await fixture.store.open(ref);
      expect((opened as Opened).text, text);
      expect(opened.readOnly, contains('not UTF-8'));
      // Writing it back would re-encode every accent in the file, so the
      // store says no rather than changing games nobody edited.
      final edited = text.replaceFirst('Nf3', 'd4');
      final saved = await fixture.replace(ref, edited, opened.revision);
      expect(saved, isA<NotWritable>());
      expect(await File(ref.path).readAsBytes(), latin1.encode(text));
    },
  );

  test('a gzipped chapter is refused, opening and saving alike', () async {
    final ref = fixture.ref('KID/Main.pgn');
    const text = '[Event "KID"]\n\n1. d4 Nf6 *\n';
    final compressed = gzip.encode(utf8.encode(text));
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(compressed);

    final opened = await fixture.store.open(ref);
    expect(opened, isA<Unreadable>());
    expect((opened as Unreadable).detail, contains('compressed'));
    // Nothing to save against: there is no revision the caller could have
    // read, and a save with the one on disk is refused too.
    final revision = await fixture.revisionOf(ref);
    expect(await fixture.replace(ref, 'mine *\n', revision), isA<IoFailure>());
    expect(await File(ref.path).readAsBytes(), compressed);
  });

  test('a chapter full of control bytes is not a document', () async {
    final ref = fixture.ref('KID/Main.pgn');
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes([0x5b, 0x00, 0x01, 0x02, 0x03, 0x04]);
    expect(await fixture.store.open(ref), isA<Unreadable>());
  });

  test('a mostly good UTF-8 file keeps its UTF-8 reading', () async {
    final ref = fixture.ref('KID/Main.pgn');
    const text = '[Event "’’’’’’’’"]\n';
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes([...utf8.encode(text), 0x9d]);
    final opened = await fixture.store.open(ref);
    expect((opened as Opened).text, '$text�');
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
    final revision = await fixture.put(ref, mine);
    final saved = await fixture.edit(ref, draft, revision);
    final receipt = (saved as Saved).receipt;
    expect(receipt.before, mine);
    expect(receipt.beforeRevision, revision);
    expect(receipt.committed, isNot(revision));
    expect(await File(ref.path).readAsString(), draft);
    expect(
      (await fixture.store.open(ref) as Opened).revision,
      receipt.committed,
    );
  });

  test('saving the same text again changes nothing', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, mine);
    final saved = await fixture.edit(ref, mine, revision);
    expect((saved as Saved).receipt.committed, revision);
    expect(fixture.keptVersions(ref), isEmpty);
  });

  test('a save against a revision the file no longer has is a conflict, and '
      'the file keeps what is on disk', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, mine);
    await File(ref.path).writeAsString(theirs);
    final result = await fixture.edit(ref, draft, revision);
    final current = (result as Conflict).current;
    expect(current, isNotNull);
    expect(current, isNot(revision));
    expect(await File(ref.path).readAsString(), theirs);
  });

  test('a save on a document that was deleted is a conflict with nothing to '
      'compare against', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, mine);
    await File(ref.path).delete();
    final result = await fixture.edit(ref, draft, revision);
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

  test('a rename waits for the folder a save has taken', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'A *\n');
    final release = Completer<void>();
    var renamed = false;
    // The scope a save holds. A rename that did not take it too could move
    // the file out from under a save that has already passed its checks, and
    // the save would then publish its copy onto the name just vacated.
    final held = withDirectoryLock(folderOf(ref), () => release.future);
    final renaming = fixture.store
        .rename(ref, 'Mainline.pgn', expected: revision)
        .then((_) => renamed = true);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(renamed, isFalse, reason: 'a writer still holds the folder');
    expect(File(ref.path).existsSync(), isTrue);

    release.complete();
    await held;
    await renaming;
    expect(File(fixture.ref('KID/Mainline.pgn').path).existsSync(), isTrue);
    expect(File(ref.path).existsSync(), isFalse);
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

  test('a move that cannot be made leaves no empty folder behind', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'moves *\n');
    // Nothing can leave a folder nobody may write to, so the move fails
    // after its destination folder has been made.
    await Process.run('chmod', ['a-w', p.dirname(ref.path)]);
    final destination = fixture.ref('Benko/Main.pgn');
    expect(
      await fixture.store.move(ref, destination, expected: revision),
      isA<IoFailure>(),
    );
    expect(
      await Directory(p.dirname(destination.path)).exists(),
      isFalse,
      reason: 'the folder the move made is not left behind',
    );
  });

  test('a moved folder carries every document and its versions', () async {
    final main = fixture.ref('KID/Main.pgn');
    final classical = fixture.ref('KID/Classical.pgn');
    final revision = await fixture.put(main, 'first *\n');
    await fixture.put(classical, '1. d4 *\n');
    // A version to carry: the store keeps what a save replaced.
    await fixture.replace(main, 'second *\n', revision);
    expect(
      await fixture.store.moveFolder(
        p.dirname(main.path),
        p.join(fixture.documents.path, "King's Indian"),
      ),
      isA<FolderMoved>(),
    );
    final moved = fixture.ref("King's Indian/Main.pgn");
    expect(await File(moved.path).readAsString(), 'second *\n');
    expect(
      await File(fixture.ref("King's Indian/Classical.pgn").path).exists(),
      isTrue,
    );
    expect(await Directory(p.dirname(main.path)).exists(), isFalse);
    expect(fixture.keptTexts(moved), ['first *\n']);
  });

  test('a folder move onto a name that is taken moves nothing', () async {
    final main = fixture.ref('KID/Main.pgn');
    await fixture.put(main, 'first *\n');
    await fixture.put(fixture.ref('Benoni/Main.pgn'), 'other *\n');
    expect(
      await fixture.store.moveFolder(
        p.dirname(main.path),
        p.join(fixture.documents.path, 'Benoni'),
      ),
      isA<FolderNameTaken>(),
    );
    expect(await File(main.path).readAsString(), 'first *\n');
    expect(
      await File(fixture.ref('Benoni/Main.pgn').path).readAsString(),
      'other *\n',
    );
  });

  test('a folder outside the documents root is refused', () async {
    expect(
      await fixture.store.moveFolder(
        p.join(fixture.root.path, 'Elsewhere'),
        p.join(fixture.documents.path, 'KID'),
      ),
      isA<FolderMoveFailed>(),
    );
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
