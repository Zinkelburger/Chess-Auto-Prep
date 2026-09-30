import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/directory_snapshot.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('unreadable books never stop a folder move', () async {
    final books = File(p.join(fixture.support.path, 'books.json'));
    await books.writeAsString('not json');
    final ref = fixture.ref('repertoires/Before/Main.pgn');
    await fixture.put(ref, oneGame('1. e4'));
    final to = p.join(fixture.documents.path, 'repertoires', 'After');
    expect(
      await fixture.store.moveFolder(p.dirname(ref.path), to),
      isA<FolderMoved>(),
    );
    expect(await File(p.join(to, 'Main.pgn')).exists(), isTrue);
    expect(await books.readAsString(), 'not json');
  });

  test('books that are not UTF-8 never stop a folder move', () async {
    final books = File(p.join(fixture.support.path, 'books.json'));
    const bytes = [0x7b, 0xff, 0xfe, 0x7d];
    await books.writeAsBytes(bytes);
    final ref = fixture.ref('repertoires/Before/Main.pgn');
    await fixture.put(ref, oneGame('1. e4'));
    final to = p.join(fixture.documents.path, 'repertoires', 'After');
    expect(
      await fixture.store.moveFolder(p.dirname(ref.path), to),
      isA<FolderMoved>(),
    );
    expect(await books.readAsBytes(), bytes);
  });

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
    'recovery-quarantine/nested',
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
      final answer = jsonEncode({'repertoireId': ref.path});
      final malformed = answer.substring(0, answer.length - 1);
      await attempts.writeAsString(malformed);

      expect(await fixture.store.moveFolder(from, to), isA<FolderMoveFailed>());
      expect(await File(ref.path).readAsString(), oneGame('1. e4'));
      expect(await Directory(to).exists(), isFalse);
      expect(await attempts.readAsString(), malformed);
    },
  );
}
