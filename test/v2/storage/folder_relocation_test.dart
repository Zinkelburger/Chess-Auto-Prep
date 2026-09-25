import 'dart:io';

import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/directory_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'Support inside the source is refused before metadata is created',
    () async {
      final ref = fixture.ref('repertoires/Before/Main.pgn');
      await fixture.put(ref, oneGame('1. e4'));
      final from = p.dirname(ref.path);
      final to = p.join(fixture.documents.path, 'repertoires', 'After');
      final support = await Directory(p.join(from, 'Support')).create();
      final snapshot = await DirectorySnapshot.capture(from);
      final owner = FileRelocations(
        documents: fixture.documents,
        support: support,
      );
      expect(
        await owner.moveFolder(from, to, operationId: 'self-source'),
        isA<FolderMoveFailed>(),
      );
      await snapshot.verify(from);
      expect(await Directory(to).exists(), isFalse);
      expect(await support.list().isEmpty, isTrue);
    },
  );

  for (final path in [
    'backups',
    '.cap-reference-history',
    'relocation-writes/nested',
    'training-writes/nested',
  ]) {
    test(
      'shared Documents and Support cannot move owned metadata $path',
      () async {
        final ref = fixture.ref('$path/Main.pgn');
        await fixture.put(ref, oneGame('1. d4'));
        final source = p.dirname(ref.path);
        final snapshot = await DirectorySnapshot.capture(source);
        final target = p.join(fixture.documents.path, 'After');
        final owner = FileRelocations(
          documents: fixture.documents,
          support: fixture.documents,
        );
        expect(
          await owner.moveFolder(source, target, operationId: 'self-metadata'),
          isA<FolderMoveFailed>(),
        );
        await snapshot.verify(source);
        expect(await Directory(target).exists(), isFalse);
      },
    );
  }

  test('moving into a metadata root does not prepare a journal', () async {
    final ref = fixture.ref('repertoires/Before/Main.pgn');
    await fixture.put(ref, oneGame('1. e4'));
    final owner = FileRelocations(
      documents: fixture.documents,
      support: fixture.documents,
    );
    expect(
      await owner.moveFolder(
        p.dirname(ref.path),
        p.join(fixture.documents.path, 'backups'),
        operationId: 'target-metadata',
      ),
      isA<FolderMoveFailed>(),
    );
    expect(await File(ref.path).exists(), isTrue);
    expect(
      await Directory(
        p.join(fixture.documents.path, 'relocation-writes'),
      ).exists(),
      isFalse,
    );
  });

  test(
    'malformed last training participant refuses before folder movement',
    () async {
      final ref = fixture.ref('repertoires/Before/Nested/Main.pgn');
      await fixture.put(ref, oneGame('1. e4'));
      final from = p.join(fixture.documents.path, 'repertoires', 'Before');
      final to = p.join(fixture.documents.path, 'repertoires', 'After');
      final attempts = File(p.join(fixture.documents.path, attemptsFile));
      const malformed = '{"repertoireId":';
      await attempts.writeAsString(malformed);

      expect(await fixture.store.moveFolder(from, to), isA<FolderMoveFailed>());
      expect(await File(ref.path).readAsString(), oneGame('1. e4'));
      expect(await Directory(to).exists(), isFalse);
      expect(await attempts.readAsString(), malformed);
    },
  );
}
