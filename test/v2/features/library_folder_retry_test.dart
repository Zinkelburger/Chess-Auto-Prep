import 'dart:async';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/book_references.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_catalog.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

void main() {
  test(
    'lost acknowledgement retries the retained folder before name checks',
    () async {
      final f = await _Fixture.create(open: true);
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      final failed = await f.rename();
      expect(failed, isA<LibraryFailure>());
      expect((failed as LibraryFailure).retry, isNotNull);
      expect(f.library.repertoires.single.path, f.to);
      expect(await f.rename(), isA<LibraryDone>());
      expect(f.store.ids, hasLength(2));
      expect(f.store.ids.first, isNotNull);
      expect(f.store.ids.last, f.store.ids.first);
      expect(f.session.source?.path, f.destination.path);
      expect(f.books.includes(f.destination), isTrue);
      expect(f.books.includes(f.chapter), isFalse);
      expect(await f.pending.settle(), isNull);
    },
  );

  test(
    'historical folder receipt cannot adopt a same-byte replacement editor',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      expect(await f.rename(), isA<LibraryFailure>());
      f.put('replacement');
      await f.session.open(f.chapter);
      await f.pending.retry(f.store);
      expect(f.store.ids, hasLength(2));
      expect(f.session.source?.path, f.chapter.path);
      expect(f.session.persistedRevision?.nativeIdentity, 'replacement');
      expect(await f.pending.settle(), isNull);
    },
  );

  test(
    'registry retry settles shared catalog before training resumes after disposal',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      expect(await f.rename(), isA<LibraryFailure>());
      f.library.dispose();
      f.libraryDisposed = true;
      f.files.hold = true;
      var completed = false;
      final retry = f.pending.retry(f.store).then((_) => completed = true);
      await pumpEventQueue();
      try {
        expect(f.store.ids, hasLength(2));
        expect(f.files.pendingCalls, 1);
        expect(completed, isFalse);
        expect(f.guard.depth, 1);
      } finally {
        f.files.hold = false;
        f.files.releaseAll();
        await retry;
      }
      expect(f.guard.depth, 0);
    },
  );

  for (final destination in [false, true]) {
    test(
      'folder drains books and holds ${destination ? 'new' : 'old'} descendants',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        f.bookStore.hold = true;
        f.books.rename(f.books.active!, 'Updated');
        await f.bookStore.entered.future;
        final moving = f.rename();
        await pumpEventQueue();
        var opened = false;
        final opening = f.session
            .open(destination ? f.destination : f.chapter)
            .then((result) {
              opened = true;
              return result;
            });
        await pumpEventQueue();
        try {
          expect(f.store.ids, isEmpty);
          expect(opened, isFalse);
          expect(f.guard.depth, 1);
        } finally {
          f.bookStore.release.complete();
        }
        expect(await moving, isA<LibraryDone>());
        expect(
          await opening,
          destination ? isA<DocumentOpened>() : isA<OpenFailed>(),
        );
        expect(f.books.active?.name, 'Updated');
        expect(f.books.includes(f.destination), isTrue);
      },
    );
  }

  test('folder capture waits for the open descendant draft to save', () async {
    final f = await _Fixture.create(open: true);
    addTearDown(f.dispose);
    f.store.inner.hold = true;
    f.session.playMove('d2d4');
    final moving = f.rename();
    await pumpEventQueue();
    expect(f.store.ids, isEmpty);
    f.store.inner.hold = false;
    f.store.inner.releaseAll();
    expect(await moving, isA<LibraryDone>());
    expect(f.session.source?.path, f.destination.path);
    expect(
      (f.store.inner.documents[f.destination] as Opened).text,
      contains('d4'),
    );
    f.session.playMove('d7d5');
    await f.saver.flush();
    expect(
      (f.store.inner.documents[f.destination] as Opened).text,
      contains('d5'),
    );
    expect(f.store.inner.documents.containsKey(f.chapter), isFalse);
  });

  test(
    'failed training admission retains the folder for an explicit retry',
    () async {
      final f = await _Fixture.create(open: true);
      addTearDown(f.dispose);
      f.guard.problem = 'A review needs recovery';
      final failed = await f.rename() as LibraryFailure;
      expect(failed.retry, isNotNull);
      expect(f.store.ids, isEmpty);
      expect(f.guard.depth, 0);
      expect(await f.pending.settle(), contains('review'));
      f.guard.problem = null;
      await f.pending.retry(f.store);
      expect(f.store.ids.single, isNotNull);
      expect(f.session.source?.path, f.destination.path);
      expect(await f.pending.settle(), isNull);
    },
  );

  for (final collided in [false, true]) {
    test(
      'import placement retains staging and exact receipt after lost acknowledgement (collision: $collided)',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        if (collided) f.store.inner.folderMoves.add(const FolderNameTaken());
        f.store.failAfterMove = true;
        final result = await f.library.importText(
          _Fixture.text,
          name: 'Imported',
        );
        expect(result, isA<LibraryFailure>());
        expect(f.files.stagingRemoved, isEmpty);
        final failed = result as LibraryFailure;
        expect(failed.retry, isNotNull);
        final acceptedId = f.store.ids.last;
        await f.pending.retry(f.store);
        final added = await failed.retry!() as LibraryAdded;
        expect(
          added.first.path,
          '/repertoires/Imported${collided ? ' (2)' : ''}/Main.pgn',
        );
        expect(added.chapters, 1);
        expect(added.lines, 1);
        expect(f.store.ids.last, acceptedId);
        expect(f.store.ids, hasLength(collided ? 3 : 2));
        expect(f.store.created, hasLength(1));
        expect(f.files.stagingRemoved, isEmpty);
        expect(await failed.retry!(), same(added));
        expect(f.store.created, hasLength(1));
        expect(await f.pending.settle(), isNull);
      },
    );
  }

  test(
    'registry success retires command before the source and destination are reused',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      final old = await f.rename() as LibraryFailure;
      await f.pending.retry(f.store);
      f.store.inner.documents.remove(f.destination);
      f.put('next');
      f.files.listing = Repertoires([f.folder]);
      await f.library.refresh();
      f.store.failBeforeMove = true;
      expect(await f.rename(), isA<LibraryFailure>());
      expect(await old.retry!(), isA<LibraryDone>());
      expect(await f.rename(), isA<LibraryDone>());
      expect(f.store.ids, hasLength(4));
      expect(f.store.ids[0], f.store.ids[1]);
      expect(f.store.ids[2], isNot(f.store.ids[0]));
      expect(f.store.ids[3], f.store.ids[2]);
      expect(
        (f.store.inner.documents[f.destination] as Opened)
            .revision
            .nativeIdentity,
        'next',
      );
    },
  );
}

final class _Fixture {
  _Fixture() {
    store = _FolderStore(bookStore, files);
    books = Books(store: bookStore, root: root, pendingWrites: pending);
    saver = DocumentSaver(
      store,
      books: books,
      pendingWrites: pending,
      writeGuard: () => guard,
      delay: Duration.zero,
    );
    session = DocumentSession(store, saver);
    catalog = RepertoireCatalog(files: files, root: root);
    library = Library(
      files: files,
      documents: store,
      saver: saver,
      session: session,
      books: books,
      pendingWrites: pending,
      picker: ScriptedPicker(),
      root: root,
      catalog: catalog,
    );
  }
  static const root = '/repertoires';
  static const text = '[Event "Main"]\n\n1. e4 e5 *\n';
  final folder = RepertoireFolder(
    name: 'Course',
    path: '$root/Course',
    modified: DateTime(2026),
    chapters: [ChapterRef.at('$root/Course/Nested/Main.pgn')],
  );
  final chapter = ChapterRef.at('$root/Course/Nested/Main.pgn');
  final destination = ChapterRef.at('$root/Moved/Nested/Main.pgn');
  final to = '$root/Moved';
  final files = ScriptedFiles();
  final pending = PendingWrites();
  final bookStore = _BookStore();
  final guard = _Guard();
  late final _FolderStore store;
  late final Books books;
  late final DocumentSaver saver;
  late final DocumentSession session;
  late final RepertoireCatalog catalog;
  late final Library library;
  bool libraryDisposed = false;

  static Future<_Fixture> create({bool open = false}) async {
    final f = _Fixture();
    f.put('original');
    f.files.listing = Repertoires([f.folder]);
    await f.books.load();
    await f.library.refresh();
    if (open) await f.session.open(f.chapter);
    return f;
  }

  void put(String identity) => store.inner.documents[chapter] = Opened(
    text,
    Revision(scriptedRevision(text).contentHash, nativeIdentity: identity),
  );
  Future<LibraryResult> rename() => library.renameRepertoire(folder, 'Moved');
  Future<void> dispose() async {
    if (bookStore.hold && !bookStore.release.isCompleted) {
      bookStore.release.complete();
    }
    files.hold = false;
    files.releaseAll();
    await pending.settle();
    if (!libraryDisposed) library.dispose();
    session.dispose();
    saver.dispose();
    books.dispose();
    catalog.dispose();
  }
}

/// A lost transport acknowledgement after the storage-owned reference commit.
final class _FolderStore implements PgnDocumentStore {
  _FolderStore(this.books, this.files);
  final inner = ScriptedDocumentStore();
  final _BookStore books;
  final ScriptedFiles files;
  final ids = <String?>[];
  final created = <DocumentRef>[];
  final _receipts = <String, FolderMoved>{};
  bool failAfterMove = false;
  bool failBeforeMove = false;

  @override
  Future<FolderMoveResult> moveFolder(
    String from,
    String to, {
    String? operationId,
  }) async {
    ids.add(operationId);
    if (operationId != null) {
      if (_receipts[operationId] case final receipt?) return receipt;
    }
    if (failBeforeMove) {
      failBeforeMove = false;
      return const FolderMoveFailed('Uncertain move');
    }
    final result = await inner.moveFolder(from, to, operationId: operationId);
    if (result is! FolderMoved) return result;
    books.value = BookList.decode(
      relocateBookReferences(
        books.value.encode(),
        repertoireRoot: _Fixture.root,
        from: from,
        to: to,
        directory: true,
      )!,
    );
    files.listing = Repertoires([
      RepertoireFolder(
        name: p.basename(to),
        path: to,
        modified: DateTime(2026),
        chapters: [
          for (final relative in result.files.keys)
            ChapterRef.at(p.join(to, relative)),
        ],
      ),
    ]);
    if (operationId != null) _receipts[operationId] = result;
    if (failAfterMove) {
      failAfterMove = false;
      return const FolderMoveFailed('Lost acknowledgement');
    }
    return result;
  }

  @override
  Future<CreateResult> create(DocumentRef ref, String text) {
    created.add(ref);
    return inner.create(ref, text);
  }

  @override
  Future<DocumentRead> open(DocumentRef ref) => inner.open(ref);
  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) => inner.save(ref, text, expected: expected, scope: scope);
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BookStore implements BookStore {
  BookList value = const BookList(
    active: 'book',
    books: [
      Book(id: 'book', name: 'Preparation', repertoires: {'Course'}),
    ],
  );
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<BookList> read() async => value;
  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: await read());

  @override
  Future<BookSnapshot> write(BookList value) async {
    if (hold) {
      entered.complete();
      await release.future;
      hold = false;
    }
    this.value = value;
    return BookSnapshot(value: value);
  }
}

final class _Guard implements DocumentWriteGuard {
  int depth = 0;
  String? problem;
  @override
  Future<String?> pauseForWrite() async {
    depth++;
    return problem;
  }

  @override
  void resumeAfterWrite() {
    depth--;
  }
}
