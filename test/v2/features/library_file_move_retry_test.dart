import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/scripted_files.dart';

void main() {
  test(
    'lost move acknowledgement retries the exact receipt and follows the open file',
    () async {
      final f = await _Fixture.create(open: true);
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      final result = await f.library.renameChapter(f.from, 'Moved');
      expect(result, isA<LibraryFailure>());
      expect((result as LibraryFailure).retry, isNotNull);
      expect(await File(f.from.path).exists(), isFalse);
      expect(await f.pending.settle(), isNotNull);
      expect(await result.retry!(), isA<LibraryDone>());
      expect(f.store.ids, hasLength(2));
      expect(f.store.ids.first, isNotNull);
      expect(f.store.ids.last, f.store.ids.first);
      expect(f.store.revisions.last, f.store.revisions.first);
      expect(f.session.source?.path, f.to.path);
      expect(f.books.includes(f.to), isTrue);
      expect(f.books.includes(f.from), isFalse);
      expect(await f.pending.settle(), isNull);
    },
  );

  test(
    'registry retry reenters training admission after Library disposal',
    () async {
      final f = await _Fixture.create(open: true);
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      expect(
        await f.library.renameChapter(f.from, 'Moved'),
        isA<LibraryFailure>(),
      );
      final before = f.guard.pauses;
      f.library.dispose();
      f.libraryDisposed = true;
      f.guard.problem = 'A review still needs recovery';
      await f.pending.retry(f.store);
      expect(f.guard.pauses, greaterThan(before));
      expect(f.store.ids, hasLength(1));
      expect(await f.pending.settle(), contains('review'));
      f.guard.problem = null;
      await f.pending.retry(f.store);
      expect(f.session.source?.path, f.to.path);
      expect(f.guard.depth, 0);
      expect(await f.pending.settle(), isNull);
    },
  );

  test(
    'accepted move Retry remains available when the catalog is stale',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.library.dispose();
      f.libraryDisposed = true;
      final files = ScriptedFiles();
      final library = Library(
        files: files,
        documents: f.store,
        saver: f.saver,
        session: f.session,
        pendingWrites: f.pending,
        picker: ScriptedPicker(),
        root: p.dirname(p.dirname(f.from.path)),
        books: f.books,
      );
      addTearDown(library.dispose);
      await library.refresh();
      f.store.failAfterMove = true;
      final failure =
          await library.renameChapter(f.from, 'Moved') as LibraryFailure;
      files.listing = const RepertoiresUnreadable('Catalog needs recovery');
      await library.refresh();
      expect(library.stale, isTrue);
      expect(library.busy, isFalse);
      expect(await failure.retry!(), isA<LibraryDone>());
      expect(f.store.ids, hasLength(2));
      expect(f.store.ids.last, f.store.ids.first);
      expect(await f.pending.settle(), isNull);
    },
  );

  test(
    'registry retry holds training through shared catalog refresh after Library disposal',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.library.dispose();
      f.libraryDisposed = true;
      final files = ScriptedFiles();
      final root = p.dirname(p.dirname(f.from.path));
      final catalog = RepertoireCatalog(files: files, root: root);
      final library = Library(
        files: files,
        documents: f.store,
        saver: f.saver,
        session: f.session,
        pendingWrites: f.pending,
        picker: ScriptedPicker(),
        root: root,
        books: f.books,
        catalog: catalog,
      );
      final sibling = ChapterRef.at(p.join(root, 'Course', 'Sibling.pgn'));
      await f.disk.put(sibling, '[Event "Sibling"]\n\n1. d4 *\n');
      await f.session.open(sibling);
      f.store.failAfterMove = true;
      expect(
        await library.renameChapter(f.from, 'Moved'),
        isA<LibraryFailure>(),
      );
      library.dispose();
      files.hold = true;
      final refreshing = catalog.refresh();
      var completed = false;
      f.store.moveAcknowledged = Completer<void>();
      final retrying = f.pending.retry(f.store).then((_) => completed = true);
      try {
        await f.store.moveAcknowledged!.future;
        await f.books.referencesSettled;
        await Future<void>.delayed(Duration.zero);
        expect(f.store.ids, hasLength(2));
        expect(files.pendingCalls, 1);
        expect(completed, isFalse);
        expect(f.guard.depth, 1);
        expect(f.session.source?.path, sibling.path);
      } finally {
        files.hold = false;
        files.releaseAll();
        await refreshing;
        await retrying;
        catalog.dispose();
      }
      expect(f.guard.depth, 0);
      expect(await f.pending.settle(), isNull);
    },
  );

  for (final destination in [false, true]) {
    test(
      'move drains books and blocks navigation to ${destination ? 'new' : 'old'} path',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        f.bookStore.hold = true;
        f.books.rename(f.books.active!, 'Updated');
        await f.bookStore.entered.future;
        final draining = Completer<void>();
        void referencesChanged() {
          if (f.books.changingReferences && !draining.isCompleted) {
            draining.complete();
          }
        }

        f.books.addListener(referencesChanged);
        final moving = f.library.renameChapter(f.from, 'Moved');
        await draining.future;
        f.books.removeListener(referencesChanged);
        expect(f.store.ids, isEmpty);
        expect(f.books.changingReferences, isTrue);
        var opened = false;
        final opening = f.session.open(destination ? f.to : f.from).then((
          result,
        ) {
          opened = true;
          return result;
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(opened, isFalse);
        f.bookStore.release.complete();
        expect(await moving, isA<LibraryDone>());
        expect(
          await opening,
          destination ? isA<DocumentOpened>() : isA<OpenFailed>(),
        );
        expect(f.books.active?.name, 'Updated');
        expect(f.books.includes(f.to), isTrue);
        expect(f.books.includes(f.from), isFalse);
      },
    );
  }

  test(
    'registry completion permits a new move at reused source and target names',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      final old =
          await f.library.renameChapter(f.from, 'Moved') as LibraryFailure;
      await f.pending.retry(f.store);
      expect(await f.pending.settle(), isNull);
      await File(
        f.to.path,
      ).rename(p.join(p.dirname(f.to.path), 'Elsewhere.pgn'));
      const next = '[Event "Replacement"]\n\n1. d4 *\n';
      await File(f.from.path).writeAsString(next);
      f.store.failBeforeMove = true;
      expect(
        await f.library.renameChapter(f.from, 'Moved'),
        isA<LibraryFailure>(),
      );
      expect(await old.retry!(), isA<LibraryDone>());
      expect(
        await f.library.renameChapter(f.from, 'Moved'),
        isA<LibraryDone>(),
      );
      expect(await File(f.from.path).exists(), isFalse);
      expect(await File(f.to.path).readAsString(), next);
      expect(f.store.ids, hasLength(4));
      expect(f.store.ids[2], f.store.ids[3]);
      expect(f.store.ids.last, isNot(f.store.ids.first));
    },
  );

  test(
    'completed retry does not rebind an editor opened on a replacement source',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.store.failAfterMove = true;
      expect(
        await f.library.renameChapter(f.from, 'Moved'),
        isA<LibraryFailure>(),
      );
      final original = await File(f.to.path).readAsString();
      await File(f.from.path).writeAsString(original);
      expect(await f.session.open(f.from), isA<DocumentOpened>());
      await f.pending.retry(f.store);
      expect(await f.pending.settle(), isNull);
      expect(f.session.source?.path, f.from.path);
      expect(await File(f.from.path).readAsString(), original);
    },
  );

  test(
    'lost delete acknowledgement retries once and closes the original editor',
    () async {
      final f = await _Fixture.create(open: true);
      addTearDown(f.dispose);
      f.store.failDeleteAt = f.from.path;
      final result = await f.library.deleteChapter(f.from);
      expect(result, isA<LibraryFailure>());
      expect((result as LibraryFailure).retry, isNotNull);
      expect(await File(f.from.path).exists(), isFalse);
      expect(f.session.source?.path, f.from.path);
      expect(await result.retry!(), isA<LibraryDone>());
      expect(f.store.deleteIds, hasLength(2));
      expect(f.store.deleteIds.first, isNotNull);
      expect(f.store.deleteIds.last, f.store.deleteIds.first);
      expect(f.store.deleteRevisions.last, f.store.deleteRevisions.first);
      expect(f.session.source, isNull);
      final recovery = ChapterRef.at(
        p.join(
          p.dirname(f.from.path),
          '.cap-pgn-history',
          '${f.store.deleteIds.first}-${p.basename(f.from.path)}',
        ),
      );
      expect(f.books.includes(recovery), isTrue);
      expect(f.books.includes(f.from), isFalse);
      expect(await f.pending.settle(), isNull);
    },
  );

  test('historical delete retry never closes a replacement editor', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final original = await File(f.from.path).readAsString();
    f.store.failDeleteAt = f.from.path;
    expect(await f.library.deleteChapter(f.from), isA<LibraryFailure>());
    await File(f.from.path).writeAsString(original);
    await f.session.open(f.from);
    expect(await f.pending.settle(), isNotNull);
    await f.pending.retry(f.store);
    expect(f.store.deleteIds, hasLength(2));
    expect(await f.pending.settle(), isNull);
    expect(f.session.source?.path, f.from.path);
    expect(await File(f.from.path).readAsString(), original);
  });

  test(
    'folder delete resumes the accepted failed file after registry recovery',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final second = ChapterRef.at(
        p.join(p.dirname(f.from.path), 'Second.pgn'),
      );
      final third = ChapterRef.at(p.join(p.dirname(f.from.path), 'Third.pgn'));
      await f.disk.put(second, '[Event "Second"]\n\n1. d4 *\n');
      await f.disk.put(third, '[Event "Third"]\n\n1. c4 *\n');
      final folder = RepertoireFolder(
        name: 'Course',
        path: p.dirname(f.from.path),
        modified: DateTime(2026),
        chapters: [f.from, second, third],
      );
      f.store.failDeleteAt = second.path;
      final result = await f.library.deleteRepertoire(folder);
      expect(result, isA<LibraryStoppedAt>());
      expect((result as LibraryStoppedAt).cause, isA<LibraryFailure>());
      expect(await File(third.path).exists(), isTrue);
      await f.pending.retry(f.store);
      expect(await f.library.deleteRepertoire(folder), isA<LibraryDone>());
      expect(f.store.deletePaths, [
        f.from.path,
        second.path,
        second.path,
        third.path,
      ]);
      expect(f.store.deleteIds[1], f.store.deleteIds[2]);
      expect(await File(third.path).exists(), isFalse);
      expect(await f.pending.settle(), isNull);
    },
  );

  test(
    'failed move retry never recaptures an external replacement revision',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.store.failBeforeMove = true;
      final result = await f.library.renameChapter(f.from, 'Moved');
      expect(result, isA<LibraryFailure>());
      expect((result as LibraryFailure).retry, isNotNull);
      const external = '[Event "External"]\n\n1. d4 *\n';
      await File(f.from.path).writeAsString(external);
      expect(await result.retry!(), isA<LibraryFailure>());
      expect(f.store.revisions.last, f.store.revisions.first);
      expect(await File(f.from.path).readAsString(), external);
      expect(await File(f.to.path).exists(), isFalse);
      expect(await f.pending.settle(), isNotNull);
    },
  );
}

final class _Fixture {
  _Fixture(
    this.disk,
    this.store,
    this.bookStore,
    this.books,
    this.pending,
    this.guard,
    this.saver,
    this.session,
    this.library,
    this.from,
    this.to,
  );
  final StoreFixture disk;
  final _LostMove store;
  final _HeldBooks bookStore;
  final Books books;
  final PendingWrites pending;
  final _Guard guard;
  final DocumentSaver saver;
  final DocumentSession session;
  final Library library;
  final ChapterRef from;
  final ChapterRef to;
  bool libraryDisposed = false;

  static Future<_Fixture> create({bool open = false}) async {
    final disk = await StoreFixture.create();
    final from = ChapterRef.at(disk.ref('repertoires/Course/Main.pgn').path);
    final to = ChapterRef.at(p.join(p.dirname(from.path), 'Moved.pgn'));
    await disk.put(from, '[Event "Line"]\n\n1. e4 *\n');
    final pending = PendingWrites();
    final bookStore = _HeldBooks(disk.store.books);
    final books = Books(
      store: bookStore,
      root: p.join(disk.documents.path, 'repertoires'),
      pendingWrites: pending,
    );
    await books.load();
    final book = books.create('Preparation')!;
    await books.settled;
    books.setChapter(
      book,
      RepertoireFolder(
        name: 'Course',
        path: p.dirname(from.path),
        modified: DateTime(2026),
        chapters: [from],
      ),
      from,
      true,
    );
    await books.settled;
    final store = _LostMove(disk.store);
    final guard = _Guard();
    final saver = DocumentSaver(
      store,
      books: books,
      pendingWrites: pending,
      delay: Duration.zero,
      writeGuard: () => guard,
    );
    final session = DocumentSession(store, saver);
    final root = p.join(disk.documents.path, 'repertoires');
    final library = Library(
      files: ChapterDirectory(Directory(root), recovery: disk.store.recovery),
      documents: store,
      saver: saver,
      session: session,
      pendingWrites: pending,
      picker: ScriptedPicker(),
      root: root,
      books: books,
    );
    await library.refresh();
    if (open) await session.open(from);
    return _Fixture(
      disk,
      store,
      bookStore,
      books,
      pending,
      guard,
      saver,
      session,
      library,
      from,
      to,
    );
  }

  Future<void> dispose() async {
    if (bookStore.hold && !bookStore.release.isCompleted) {
      bookStore.release.complete();
    }
    await pending.settle();
    if (!libraryDisposed) library.dispose();
    session.dispose();
    saver.dispose();
    books.dispose();
    await disk.dispose();
  }
}

final class _LostMove implements PgnDocumentStore {
  _LostMove(this.inner);
  final PgnDocumentStore inner;
  final ids = <String?>[];
  final revisions = <Revision>[];
  final deleteIds = <String?>[];
  final deleteRevisions = <Revision>[];
  final deletePaths = <String>[];
  String? failDeleteAt;
  bool failAfterMove = false;
  bool failBeforeMove = false;
  Completer<void>? moveAcknowledged;
  @override
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
    String? operationId,
  }) async {
    ids.add(operationId);
    revisions.add(expected);
    if (failBeforeMove) {
      failBeforeMove = false;
      return const IoFailure('Uncertain move');
    }
    final result = await inner.move(
      ref,
      destination,
      expected: expected,
      operationId: operationId,
    );
    moveAcknowledged?.complete();
    if (failAfterMove && result is Moved) {
      failAfterMove = false;
      return const IoFailure('Lost acknowledgement');
    }
    return result;
  }

  @override
  Future<DeleteResult> delete(
    DocumentRef ref, {
    required Revision expected,
    String? operationId,
  }) async {
    deleteIds.add(operationId);
    deleteRevisions.add(expected);
    deletePaths.add(ref.path);
    final result = await inner.delete(
      ref,
      expected: expected,
      operationId: operationId,
    );
    if (failDeleteAt == ref.path && result is Deleted) {
      failDeleteAt = null;
      return const IoFailure('Lost delete acknowledgement');
    }
    return result;
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

final class _HeldBooks implements BookStore {
  _HeldBooks(this.inner);
  final BookStore inner;
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<BookList> read() => inner.read();
  @override
  Future<void> write(BookList value) async {
    if (hold) {
      entered.complete();
      await release.future;
      hold = false;
    }
    await inner.write(value);
  }
}

final class _Guard implements DocumentWriteGuard {
  int pauses = 0;
  int depth = 0;
  String? problem;
  @override
  Future<String?> pauseForWrite() async {
    pauses++;
    depth++;
    return problem;
  }

  @override
  void resumeAfterWrite() {
    depth--;
  }
}
