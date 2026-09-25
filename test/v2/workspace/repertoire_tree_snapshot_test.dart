import 'dart:io';

import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';

void main() {
  late StoreFixture fixture;
  late DocumentSaver saver;
  late DocumentSession session;
  late Books books;
  late RepertoireShelf shelf;
  late RepertoireTree tree;
  var failPublication = false;
  final first = BookList(
    active: 'a',
    books: [
      Book(
        id: 'a',
        name: 'A',
        chapters: {const BookChapter('White/A.pgn', null)},
      ),
    ],
  );
  final second = BookList(
    active: 'a',
    books: [
      Book(
        id: 'a',
        name: 'A',
        chapters: {const BookChapter('White/B.pgn', null)},
      ),
    ],
  );

  setUp(() async {
    fixture = await StoreFixture.create();
    failPublication = false;
    final source = ChapterRef.at(fixture.ref('repertoires/White/A.pgn').path);
    await fixture.put(source, '// Color: White\n\n[Event "A"]\n\n1. e4 e5 *');
    await fixture.put(
      fixture.ref('repertoires/White/B.pgn'),
      '// Color: White\n\n[Event "B"]\n\n1. d4 d5 *',
    );
    await fixture.store.books.write(first);
    saver = DocumentSaver(fixture.store);
    session = DocumentSession(fixture.store, saver);
    await session.open(source);
    books = Books(
      store: BookFile(
        fixture.support,
        recovery: fixture.store.recovery,
        publish: (path, bytes, {installed}) async {
          if (failPublication) throw const FileSystemException('disk full');
          await replaceFile(path, bytes, installed: installed);
        },
      ),
      root: p.join(fixture.documents.path, 'repertoires'),
    );
    await books.load();
    shelf = RepertoireShelf(
      files: ChapterDirectory(
        Directory(p.join(fixture.documents.path, 'repertoires')),
        recovery: fixture.store.recovery,
      ),
      documents: fixture.store,
    );
    tree = RepertoireTree(session: session, shelf: shelf, books: books);
  });

  tearDown(() async {
    tree.dispose();
    shelf.dispose();
    books.dispose();
    session.dispose();
    saver.dispose();
    await fixture.dispose();
  });

  Future<void> settled() async {
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (tree.state is TreeReading && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(tree.state, isNot(isA<TreeReading>()));
  }

  test(
    'native book changes cannot certify a tree built from old membership',
    () async {
      await fixture.store.books.write(second);
      tree.watch();
      await settled();
      expect(tree.state, isA<TreeUnavailable>());
      expect(tree.current, isFalse);
    },
  );

  test('retry refreshes externally changed native book membership', () async {
    await fixture.store.books.write(second);
    tree.watch();
    await settled();
    expect(tree.state, isA<TreeUnavailable>());
    await tree.retry();
    expect(
      tree.current,
      isTrue,
      reason:
          '${tree.state}; books current=${books.current}; shelf stale=${shelf.stale}; ${switch (tree.state) {
            TreeUnavailable(:final detail) => detail,
            _ => '',
          }}',
    );
    expect((tree.state as TreeShown).rows.map((row) => row.san), ['d4']);
  });

  test(
    'retry settles a failed native book edit before certifying rows',
    () async {
      failPublication = true;
      books.rename(books.active!, 'Retained name');
      await books.settled;
      tree.watch();
      expect(tree.state, isA<TreeUnavailable>());
      expect(books.canRetry, isTrue);
      failPublication = false;
      await tree.retry();
      expect(books.canRetry, isFalse);
      expect(books.active!.name, 'Retained name');
      expect(tree.current, isTrue);
    },
  );

  test('reopening a cached tree validates its book source again', () async {
    tree.watch();
    await settled();
    expect(tree.current, isTrue);
    tree.unwatch();
    await fixture.store.books.write(second);
    tree.watch();
    await settled();
    expect(tree.state, isA<TreeUnavailable>());
    expect(tree.current, isFalse);
  });

  test(
    'no active book also validates the native absence of a selection',
    () async {
      await fixture.store.books.write(BookList.empty);
      await books.load();
      await fixture.store.books.write(second);
      tree.watch();
      await settled();
      expect(tree.state, isA<TreeUnavailable>());
    },
  );
}
