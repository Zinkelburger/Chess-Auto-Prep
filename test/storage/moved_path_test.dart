// What a recorded move decides from where its file or folder is when it is
// finished later: a move whose source went away, or was replaced, is set
// aside rather than taken to have landed; a rename the disk refused takes
// back the folders it made.
@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  /// An owner whose moves stop once they are written down, before anything
  /// is renamed.
  FileRelocations stopping() => FileRelocations(
    documents: fixture.documents,
    support: fixture.support,
    testHook: (step) async {
      if (step == FileRelocationStep.intent) {
        throw const FileSystemException('stopped after the record');
      }
    },
  );

  FileRelocations plain() =>
      FileRelocations(documents: fixture.documents, support: fixture.support);

  test('a recorded move whose PGN was deleted meanwhile is set aside, not '
      'taken to have landed', () async {
    final a = fixture.ref('repertoires/Course/A.pgn');
    final b = fixture.ref('repertoires/Course/B.pgn');
    final revision = await fixture.put(a, oneGame('1. e4'));
    await fixture.train(a);
    expect(
      await stopping().move(a, b, expected: revision, operationId: 'move'),
      isNot(isA<Moved>()),
    );
    await File(a.path).delete();
    await plain().recover();
    expect(fixture.unfinishedMoves(), isEmpty);
    expect(fixture.quarantined(), isNotEmpty);
    expect(File(b.path).existsSync(), isFalse);
  });

  group('a recorded folder move', () {
    late String from;
    late String to;
    setUp(() async {
      final a = fixture.ref('repertoires/KID/A.pgn');
      await fixture.put(a, oneGame('1. e4'));
      from = p.dirname(a.path);
      to = p.join(p.dirname(from), 'KID2');
      expect(
        await stopping().moveFolder(from, to, operationId: 'folder'),
        isNot(isA<FolderMoved>()),
      );
      expect(fixture.unfinishedMoves(), isNotEmpty);
    });

    test('whose folder was deleted meanwhile is set aside', () async {
      await Directory(from).delete(recursive: true);
      await plain().recover();
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(fixture.quarantined(), isNotEmpty);
      expect(Directory(to).existsSync(), isFalse);
    });

    test('whose folder was replaced by another of the same name moves '
        'nothing', () async {
      await Directory(from).delete(recursive: true);
      await File(p.join(from, 'A.pgn')).create(recursive: true);
      await plain().recover();
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(fixture.quarantined(), isNotEmpty);
      expect(Directory(to).existsSync(), isFalse);
      expect(File(p.join(from, 'A.pgn')).existsSync(), isTrue);
    });
  });

  test('a rename the disk refuses takes back the folder made for it', () async {
    final a = fixture.ref('repertoires/Course/A.pgn');
    final revision = await fixture.put(a, oneGame('1. e4'));
    final course = p.dirname(a.path);
    final made = p.join(fixture.documents.path, 'repertoires', 'New');
    await Process.run('chmod', ['555', course]);
    addTearDown(() => Process.run('chmod', ['755', course]));
    final result = await plain().move(
      a,
      fixture.ref('repertoires/New/A.pgn'),
      expected: revision,
      operationId: 'refused',
    );
    expect(result, isNot(isA<Moved>()));
    expect(Directory(made).existsSync(), isFalse);
    expect(File(a.path).existsSync(), isTrue);
  });
}
