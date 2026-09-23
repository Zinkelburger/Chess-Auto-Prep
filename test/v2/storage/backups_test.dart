// The versions a write replaces, kept under Support.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  // One-game chapters, so a save can say which game it edits and the kept
  // versions are the kind of file the user really has.
  final a = oneGame('1. d4');
  final b = oneGame('1. e4');
  final c = oneGame('1. c4');
  final d = oneGame('1. Nf3');
  final older = oneGame('1. b3');
  final newer = oneGame('1. g3');

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('every version a save replaced is kept, oldest first', () async {
    final ref = fixture.ref('KID/Main.pgn');
    var revision = await fixture.put(ref, a);
    for (final text in [b, c, d]) {
      final saved = await fixture.edit(ref, text, revision) as Saved;
      revision = saved.receipt.committed;
    }
    expect(fixture.keptTexts(ref), [a, b, c]);
    expect(fixture.keptVersions(ref).first, endsWith('.pgn'));
    expect(fixture.keptVersions(ref).first, isNot(endsWith('.pgn.gz')));
  });

  test('a save that replaces nothing keeps nothing', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, a);
    final saved = await fixture.edit(ref, a, revision) as Saved;
    expect(fixture.keptVersions(ref), isEmpty);
    expect(saved.receipt.committed, revision);
  });

  test('a deleted document leaves its bytes behind', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, a);
    expect(await fixture.store.delete(ref, expected: revision), isA<Deleted>());
    expect(fixture.keptTexts(ref), [a]);
  });

  test('a renamed document keeps one history', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final first = await fixture.put(ref, a);
    final saved = await fixture.edit(ref, b, first) as Saved;
    final moved = await fixture.store.rename(
      ref,
      'Mainline.pgn',
      expected: saved.receipt.committed,
    );
    final renamed = fixture.ref('KID/Mainline.pgn');
    expect(fixture.keptTexts(renamed), [a]);
    expect(fixture.backupFolder(ref).existsSync(), isFalse);
    final after = await fixture.edit(renamed, c, (moved as Moved).revision);
    expect(after, isA<Saved>());
    expect(fixture.keptTexts(renamed), [a, b]);
  });

  test('a list of versions nobody can read is written again', () async {
    final ref = fixture.ref('KID/Main.pgn');
    var revision = await fixture.put(ref, a);
    revision =
        (await fixture.edit(ref, b, revision) as Saved).receipt.committed;
    final kept = fixture.keptVersions(ref);
    final index = File(p.join(fixture.backupFolder(ref).path, 'index.json'));
    await index.writeAsString('{"versions": [{"fi');

    final saved = await fixture.edit(ref, c, revision);

    expect(saved, isA<Saved>(), reason: 'a broken list is not a lost save');
    expect(await File(ref.path).readAsString(), c);
    // Both versions the file still holds are listed again, with the new one.
    expect(fixture.keptTexts(ref), [a, b]);
    expect(fixture.keptVersions(ref), containsAll(kept));
    final aside = fixture
        .backupFolder(ref)
        .listSync()
        .map((e) => p.basename(e.path));
    expect(aside, contains(startsWith('index.json.corrupt-')));
  });

  test(
    'a list of versions whose bytes are not text is written again',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      var revision = await fixture.put(ref, a);
      revision =
          (await fixture.edit(ref, b, revision) as Saved).receipt.committed;
      final index = File(p.join(fixture.backupFolder(ref).path, 'index.json'));
      // A list that would read but for one byte: 0xC3 starts a character the
      // quote after it does not finish.
      await index.writeAsBytes([
        ...utf8.encode('{"path": "Main'),
        0xC3,
        ...utf8.encode('", "versions": []}'),
      ]);

      final saved = await fixture.edit(ref, c, revision);

      expect(saved, isA<Saved>(), reason: 'a broken list is not a lost save');
      expect(fixture.keptTexts(ref), [a, b]);
      expect(
        fixture.backupFolder(ref).listSync().map((e) => p.basename(e.path)),
        contains(startsWith('index.json.corrupt-')),
      );
    },
  );

  test('what an interrupted write left behind is no version', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, a);
    final folder = fixture.backupFolder(ref);
    await folder.create(recursive: true);
    // A version whose write was killed: the staged copy is all that is there,
    // and it holds half a chapter.
    final staged = File(
      temporaryPathFor(p.join(folder.path, '20260101T000000000Z-11111111.pgn')),
    );
    await staged.writeAsString('[Event "Half a ga');
    await File(p.join(folder.path, 'index.json')).writeAsString('not a list');

    expect(await fixture.edit(ref, b, revision), isA<Saved>());

    expect(fixture.keptTexts(ref), [a], reason: 'only the whole version');
    expect(staged.existsSync(), isTrue, reason: 'nothing here deletes it');
  });

  test('a history already kept under the new name is not braided in', () async {
    // A chapter that used to have the name, removed outside this app, so its
    // versions are still kept under the id that name hashes to.
    final taken = fixture.ref('KID/Mainline.pgn');
    final first = await fixture.put(taken, older);
    await fixture.edit(taken, newer, first);
    await File(taken.path).delete();

    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, a);
    final saved = await fixture.edit(ref, b, revision) as Saved;
    final moved = await fixture.store.rename(
      ref,
      'Mainline.pgn',
      expected: saved.receipt.committed,
    );

    expect(moved, isA<Moved>());
    expect(fixture.keptTexts(taken), [a]);
    final superseded = Directory(p.join(fixture.support.path, 'backups'))
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).contains('.superseded-'))
        .single;
    expect(superseded.listSync(), hasLength(2));
  });

  test('versions committed in one millisecond keep one order', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, a);
    final folder = fixture.backupFolder(ref);
    await folder.create(recursive: true);
    // Versions the same stamp cannot tell apart; only their names can, and
    // the folder hands them back in whatever order it pleases. Some were
    // kept gzipped by an earlier build, and are read all the same.
    const names = ['66666666', '55555555', '44444444', '33333333', '22222222'];
    for (final (index, name) in names.indexed) {
      final bytes = utf8.encode('$name *\n');
      await File(
        p.join(
          folder.path,
          '20260101T000000000Z-$name${index.isEven ? '.pgn.gz' : '.pgn'}',
        ),
      ).writeAsBytes(index.isEven ? gzip.encode(bytes) : bytes);
    }
    await File(
      p.join(folder.path, 'index.json'),
    ).writeAsString('not a list of versions');

    expect(await fixture.edit(ref, b, revision), isA<Saved>());

    expect(fixture.keptTexts(ref).take(names.length), [
      for (final name in names.reversed) '$name *\n',
    ]);
    expect(fixture.keptTexts(ref).last, a);
  });

  test('an adoption that cannot be made moves no history at all', () async {
    final taken = fixture.ref('KID/Mainline.pgn');
    final first = await fixture.put(taken, older);
    await fixture.edit(taken, newer, first);
    await File(taken.path).delete();
    final occupied = fixture.backupFolder(taken);
    final occupantHeld = occupied.listSync().map((e) => p.basename(e.path));

    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, a);
    final saved = await fixture.edit(ref, b, revision) as Saved;
    final mineHeld = fixture
        .backupFolder(ref)
        .listSync()
        .map((e) => p.basename(e.path));
    // The name the incoming history has to wait under is taken, by what an
    // adoption that was interrupted left behind.
    await Directory('${occupied.path}.adopting').create();

    final moved = await fixture.store.rename(
      ref,
      'Mainline.pgn',
      expected: saved.receipt.committed,
    );

    expect(moved, isA<Moved>(), reason: 'the chapter still moves');
    // Neither history was disturbed, and nothing was set aside.
    expect(occupied.listSync().map((e) => p.basename(e.path)), occupantHeld);
    expect(
      fixture.backupFolder(ref).listSync().map((e) => p.basename(e.path)),
      mineHeld,
    );
    expect(
      Directory(
        p.join(fixture.support.path, 'backups'),
      ).listSync().where((e) => p.basename(e.path).contains('.superseded-')),
      isEmpty,
    );
  });

  test(
    'a version that cannot be kept stops the save, and the document stands',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, a);
      await Directory(p.join(fixture.support.path, 'backups')).create();
      await Process.run('chmod', [
        '500',
        p.join(fixture.support.path, 'backups'),
      ]);
      final result = await fixture.edit(ref, b, revision);
      expect(result, isA<IoFailure>());
      expect((result as IoFailure).detail, contains('could not be kept'));
      expect(await File(ref.path).readAsString(), a);
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'needs a Linux user without root'
        : false,
  );
}
