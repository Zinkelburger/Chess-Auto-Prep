// The versions a write replaces, kept under Support.
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('every version a save replaced is kept, oldest first', () async {
    final ref = fixture.ref('KID/Main.pgn');
    var revision = await fixture.put(ref, 'A *\n');
    for (final text in ['B *\n', 'C *\n', 'D *\n']) {
      final saved =
          await fixture.store.save(ref, text, expected: revision) as Saved;
      revision = saved.receipt.committed;
    }
    expect(fixture.keptTexts(ref), ['A *\n', 'B *\n', 'C *\n']);
    expect(fixture.keptVersions(ref).first, endsWith('.pgn.gz'));
  });

  test('a save that replaces nothing keeps nothing', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'A *\n');
    final saved =
        await fixture.store.save(ref, 'A *\n', expected: revision) as Saved;
    expect(fixture.keptVersions(ref), isEmpty);
    expect(saved.receipt.committed, revision);
  });

  test('a deleted document leaves its bytes behind', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, 'A *\n');
    expect(await fixture.store.delete(ref, expected: revision), isA<Deleted>());
    expect(fixture.keptTexts(ref), ['A *\n']);
  });

  test('a renamed document keeps one history', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final first = await fixture.put(ref, 'A *\n');
    final saved =
        await fixture.store.save(ref, 'B *\n', expected: first) as Saved;
    final moved = await fixture.store.rename(
      ref,
      'Mainline.pgn',
      expected: saved.receipt.committed,
    );
    final renamed = fixture.ref('KID/Mainline.pgn');
    expect(fixture.keptTexts(renamed), ['A *\n']);
    expect(fixture.backupFolder(ref).existsSync(), isFalse);
    final after = await fixture.store.save(
      renamed,
      'C *\n',
      expected: (moved as Moved).revision,
    );
    expect(after, isA<Saved>());
    expect(fixture.keptTexts(renamed), ['A *\n', 'B *\n']);
  });

  test(
    'a version that cannot be kept stops the save, and the document stands',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, 'A *\n');
      await Directory(p.join(fixture.support.path, 'backups')).create();
      await Process.run('chmod', [
        '500',
        p.join(fixture.support.path, 'backups'),
      ]);
      final result = await fixture.store.save(ref, 'B *\n', expected: revision);
      expect(result, isA<IoFailure>());
      expect((result as IoFailure).detail, contains('could not be kept'));
      expect(await File(ref.path).readAsString(), 'A *\n');
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'needs a Linux user without root'
        : false,
  );
}
