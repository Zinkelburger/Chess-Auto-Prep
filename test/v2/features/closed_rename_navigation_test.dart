import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/viewer_fixture.dart';

void main() {
  test(
    'opening waits for a closed rename while accepted books drain',
    () async {
      final disk = await StoreFixture.create();
      final ref = ChapterRef.at(
        disk.ref('repertoires/Course/Course.pgn').path,
        section: 'A',
      );
      await disk.put(ref, '[Event "Line"]\n[ChapterName "A"]\n\n1. e4 *\n');
      final bookStore = _DelayedBooks(disk.store.books);
      final books = Books(
        store: bookStore,
        root: p.join(disk.documents.path, 'repertoires'),
      );
      await books.load();
      final saver = DocumentSaver(
        disk.store,
        books: books,
        delay: Duration.zero,
      );
      final session = DocumentSession(disk.store, saver);
      final root = p.join(disk.documents.path, 'repertoires');
      final library = Library(
        files: ChapterDirectory(Directory(root), recovery: disk.store.recovery),
        documents: disk.store,
        saver: saver,
        session: session,
        picker: ScriptedPicker(),
        root: root,
        books: books,
      );
      addTearDown(() async {
        library.dispose();
        session.dispose();
        saver.dispose();
        books.dispose();
        await disk.dispose();
      });
      books.create('Preparation');
      await bookStore.entered.future;
      final rename = library.renameChapter(ref, 'B');
      while (!books.changingReferences) {
        await Future<void>.delayed(Duration.zero);
      }
      var opened = false;
      final opening = session.open(ref).then((result) {
        opened = true;
        return result;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        opened,
        isFalse,
        reason:
            'The old section must not open as Saved during a pending rename.',
      );
      bookStore.release.complete();
      expect(await rename, isA<LibraryDone>());
      expect(await opening, isA<OpenFailed>());
      expect(session.source, isNull);
      expect(
        await session.open(ChapterRef.at(ref.path, section: 'B')),
        isA<DocumentOpened>(),
      );
      expect(session.source?.section, 'B');
      expect(saver.settled, isTrue);
    },
  );

  test(
    'a target change during navigation callbacks invalidates already-read text',
    () async {
      final disk = await StoreFixture.create();
      final ref = ChapterRef.at(disk.ref('repertoires/Course/Course.pgn').path);
      const before = '[Event "Line"]\n[ChapterName "A"]\n\n1. e4 *\n';
      final after = before.replaceFirst('"A"', '"B"');
      await disk.put(ref, before);
      final saver = DocumentSaver(disk.store, delay: Duration.zero);
      final session = DocumentSession(disk.store, saver);
      addTearDown(() async {
        session.dispose();
        saver.dispose();
        await disk.dispose();
      });
      var changed = false;
      session.leaving.addListener(() {
        if (changed) return;
        changed = true;
        unawaited(
          session.access.changing(ref.path, () async {
            await File(ref.path).writeAsString(after);
          }),
        );
      });
      expect(await session.open(ref), isA<DocumentOpened>());
      expect(writeChapter(session.chapter!), contains('[ChapterName "B"]'));
      expect(saver.settled, isTrue);
    },
  );
}

final class _DelayedBooks implements BookStore {
  _DelayedBooks(this.inner);
  final BookStore inner;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<BookList> read() => inner.read();
  @override
  Future<BookSnapshot> snapshot() => inner.snapshot();

  @override
  Future<BookSnapshot> write(BookList value) async {
    entered.complete();
    await release.future;
    return inner.write(value);
  }
}
