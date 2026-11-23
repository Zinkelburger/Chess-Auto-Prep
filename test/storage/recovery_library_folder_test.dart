import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/chapter_directory.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/deleted_chapters.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

/// The library folder itself in the way of recovery: a link to somewhere
/// else, a link that leads nowhere because its drive is not connected, and
/// a file standing where the folder should be.
PgnFileStore _restarted(StoreFixture fixture) =>
    PgnFileStore(documents: fixture.documents, support: fixture.support);

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'a linked repertoires folder still keys the profile lock by its target',
    () async {
      final target = await Directory(
        p.join(fixture.root.path, 'shelves'),
      ).create();
      await Link(
        p.join(fixture.documents.path, 'repertoires'),
      ).create(target.path);
      final key = Directory(
        p.join(await target.resolveSymbolicLinks(), '.cap-directory-domain'),
      );
      final gate = fixture.store.recovery;
      await gate.run(() async {});
      var entered = false;
      late Future<void> access;
      await withDirectoryLock(key, () async {
        access = gate.run(() async {
          entered = true;
        });
        await expectLater(
          access.timeout(const Duration(milliseconds: 200)),
          throwsA(isA<TimeoutException>()),
        );
        expect(entered, isFalse);
      });
      await access;
      expect(entered, isTrue);
    },
    skip: Platform.isWindows ? 'symlink privileges not assumed' : false,
  );

  test('a file named repertoires leaves studies and books readable', () async {
    // This Documents folder already contains a user file with that name
    // when the application first opens the profile.
    final file = await File(
      p.join(fixture.documents.path, 'repertoires'),
    ).writeAsString('notes');
    final root = await Directory(
      p.join(fixture.documents.path, 'studies'),
    ).create();
    final study = await File(
      p.join(root.path, 'Endgame.pgn'),
    ).writeAsString(oneGame('1. c4'));
    const books = BookList(
      books: [Book(id: 'a', name: 'Match prep')],
      active: 'a',
    );
    await File(
      p.join(fixture.support.path, 'books.json'),
    ).writeAsString(books.encode());
    final store = _restarted(fixture);
    final studies = StudyDirectory(root, recovery: store.recovery);
    await Future.wait([
      expectLater(
        studies.list(),
        completion(
          isA<StudiesListed>().having(
            (listed) => listed.studies.map((ref) => ref.path),
            'studies',
            [study.path],
          ),
        ),
      ),
      expectLater(
        store.books.snapshot().then((read) => read.value.activeBook?.name),
        completion('Match prep'),
      ),
    ]);
    final chapters = ChapterDirectory(
      Directory(file.path),
      recovery: store.recovery,
    );
    expect(await chapters.list(), isA<RepertoiresUnreadable>());
    expect(await chapters.deleted(), isA<DeletedUnreadable>());
    expect(await file.readAsString(), 'notes');
  });

  test(
    'a disconnected library keeps a landed rename until it can finish',
    () async {
      final before = fixture.ref('repertoires/Course/Old.pgn');
      final after = fixture.ref('repertoires/Course/New.pgn');
      final revision = await fixture.put(before, oneGame('1. d4'));
      await fixture.train(before);
      await _landedMove(fixture, before, after, revision);
      final root = Directory(p.join(fixture.documents.path, 'repertoires'));
      final offline = await root.rename(p.join(fixture.root.path, 'offline'));
      final link = Link(root.path);
      await link.create(p.join(fixture.root.path, 'drive'));
      final store = _restarted(fixture);
      final read = await store.open(after);
      expect(_owedMoves(fixture), hasLength(1));
      expect(fixture.quarantined(), isEmpty);
      expect(read, isA<Unreadable>());
      await link.delete();
      await offline.rename(root.path);
      expect(await store.open(after), isA<Opened>());
      expect(_owedMoves(fixture), isEmpty);
      await fixture.expectTrained(after);
    },
    skip: Platform.isWindows,
  );
}

Future<void> _landedMove(
  StoreFixture fixture,
  DocumentRef from,
  DocumentRef to,
  Revision revision,
) async {
  final stopping = PgnFileStore(
    documents: fixture.documents,
    support: fixture.support,
    relocationHook: stopOnceAt(FileRelocationStep.document.name),
  );
  expect(
    await stopping.move(from, to, expected: revision, operationId: 'landed'),
    isNot(isA<Moved>()),
  );
  expect(File(to.path).existsSync(), isTrue);
  expect(_owedMoves(fixture), isNotEmpty);
}

/// The relocation records still to finish.
List<FileSystemEntity> _owedMoves(StoreFixture fixture) {
  final folder = Directory(
    p.join(fixture.support.path, FileRelocations.journal),
  );
  return folder.existsSync()
      ? folder.listSync().whereType<File>().toList()
      : const [];
}
