import 'dart:io';
import 'dart:convert';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' as storage;
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/viewer_fixture.dart';

const _course =
    '// Color: White\n\n[Event "A line"]\n[ChapterName "A"]\n\n1. e4 *\n\n[Event "Sibling"]\n[ChapterName "Sibling"]\n\n1. d4 *\n';

void main() {
  late StoreFixture disk;
  late Books books;
  late PgnFileStore store;
  CompoundWriteStep? failAt;
  late DocumentSaver saver;
  late DocumentSession session;
  late Library library;
  late ChapterRef original;
  late File bookFile;
  const training = [
    'repertoire_reviews.csv',
    'repertoire_move_progress.csv',
    'repertoire_review_history.csv',
    'repertoire_move_attempts.jsonl',
  ];

  setUp(() async {
    disk = await StoreFixture.create();
    failAt = null;
    store = PgnFileStore(
      documents: disk.documents,
      support: disk.support,
      compoundHook: (step) async {
        if (step == failAt) {
          failAt = null;
          throw StateError("lost acknowledgement");
        }
      },
    );
    original = ChapterRef.at(
      disk.ref('repertoires/Course/Course.pgn').path,
      section: 'A',
    );
    await disk.put(original, _course);
    bookFile = File(p.join(disk.support.path, 'books.json'));
    await bookFile.writeAsString(
      BookList(
        active: 'one',
        books: [
          Book(
            id: 'one',
            name: 'Preparation',
            chapters: {BookChapter('Course/Course.pgn', 'A')},
          ),
        ],
      ).encode(),
    );
    final root = p.join(disk.documents.path, 'repertoires');
    books = Books(store: store.books, root: root);
    await books.load();
    saver = DocumentSaver(store, delay: Duration.zero, books: books);
    session = DocumentSession(store, saver);
    library = Library(
      files: ChapterDirectory(Directory(root), recovery: store.recovery),
      documents: store,
      saver: saver,
      session: session,
      picker: ScriptedPicker(),
      root: root,
      books: books,
    );
    for (final name in training) {
      await File(
        p.join(disk.documents.path, name),
      ).writeAsString('unchanged $name\n');
    }
    await library.refresh();
    await session.open(original);
  });
  tearDown(() async {
    library.dispose();
    session.dispose();
    saver.dispose();
    books.dispose();
    for (final name in training) {
      expect(
        await File(p.join(disk.documents.path, name)).readAsString(),
        'unchanged $name\n',
      );
    }
    await disk.dispose();
  });

  test(
    'committed rename and undo move the active book with the section',
    () async {
      expect(await library.renameChapter(original, 'B'), isA<LibraryDone>());
      await books.settled;
      expect((await bookFile.readAsString()), contains('"B"'));
      expect(await session.undo(), isA<Restored>());
      await books.settled;
      expect(
        await File(original.path).readAsString(),
        contains('[ChapterName "A"]'),
      );
      expect(books.includes(original), isTrue);
      expect(await bookFile.readAsString(), contains('"A"'));
    },
  );

  test('held rename and draft undo never publish book references', () async {
    final before = await bookFile.readAsString();
    session.holdsEdits = true;
    await library.renameChapter(original, 'B');
    await books.settled;
    expect(session.source?.section, 'B');
    expect(await File(original.path).readAsString(), _course);
    expect(await bookFile.readAsString(), before);
    expect(await session.undo(), isA<Restored>());
    expect(session.source?.section, 'A');
    expect(await bookFile.readAsString(), before);
  });

  test(
    'keeping a held rename publishes both participants and committed undo restores them',
    () async {
      final before = await bookFile.readAsString();
      session.holdsEdits = true;
      expect(await library.renameChapter(original, 'B'), isA<LibraryDone>());
      session.keepHeld();
      await saver.flush();
      expect(saver.settled, isTrue);
      expect(
        books.includes(ChapterRef.at(original.path, section: 'B')),
        isTrue,
      );
      expect(await session.undo(), isA<Restored>());
      expect(await bookFile.readAsString(), before);
    },
  );

  test(
    'held rename chain is one compound operation and preserves unknown book fields',
    () async {
      final json =
          jsonDecode(await bookFile.readAsString()) as Map<String, Object?>;
      json['future'] = {
        'preserved': [1, 2],
      };
      await bookFile.writeAsString(jsonEncode(json));
      await books.load();
      final before = await bookFile.readAsString();
      session.holdsEdits = true;
      await library.renameChapter(original, 'B');
      await library.renameChapter(
        ChapterRef.at(original.path, section: 'B'),
        'C',
      );
      session.keepHeld();
      await saver.flush();
      expect(saver.settled, isTrue);
      expect(
        books.includes(ChapterRef.at(original.path, section: 'C')),
        isTrue,
      );
      expect(jsonDecode(await bookFile.readAsString())['future'], {
        'preserved': [1, 2],
      });
      expect(await session.undo(), isA<Restored>());
      expect(await bookFile.readAsString(), before);
    },
  );

  test(
    'discarding held rename restores selection without any publication',
    () async {
      final before = await bookFile.readAsString();
      session.holdsEdits = true;
      await library.renameChapter(original, 'B');
      session.discardHeld();
      expect(session.source, original);
      expect(await File(original.path).readAsString(), _course);
      expect(await bookFile.readAsString(), before);
      expect(
        await Directory(p.join(disk.support.path, 'compound-writes')).exists(),
        isFalse,
      );
    },
  );

  test(
    'undo refuses an externally changed book without changing either participant',
    () async {
      await library.renameChapter(original, 'B');
      final renamed = await File(original.path).readAsString();
      final external = (await bookFile.readAsString()).replaceFirst(
        'Preparation',
        'External',
      );
      await bookFile.writeAsString(external);
      expect(await session.undo(), isA<UndoRefused>());
      expect(await File(original.path).readAsString(), renamed);
      expect(await bookFile.readAsString(), external);
      expect(saver.settled, isFalse);
    },
  );

  test(
    'a closed-file rename asked again after a lost acknowledgement is done',
    () async {
      session.closed();
      failAt = CompoundWriteStep.document;
      expect(await library.renameChapter(original, 'B'), isA<LibraryFailure>());
      final renamed = await File(original.path).readAsString();
      expect(renamed, contains('[ChapterName "B"]'));
      expect(await library.renameChapter(original, 'B'), isA<LibraryDone>());
      expect(await File(original.path).readAsString(), renamed);
      expect(
        books.includes(ChapterRef.at(original.path, section: 'B')),
        isTrue,
      );
      final receipts = await Directory(
        p.join(disk.support.path, 'compound-writes'),
      ).list().toList();
      expect(receipts, hasLength(1));
    },
  );

  test(
    'open-file rename retries the same operation after lost acknowledgement',
    () async {
      failAt = CompoundWriteStep.document;
      expect(await library.renameChapter(original, 'B'), isA<LibraryFailure>());
      await saver.flush();
      expect(saver.settled, isTrue);
      expect(
        books.includes(ChapterRef.at(original.path, section: 'B')),
        isTrue,
      );
      expect(await session.undo(), isA<Restored>());
      expect(books.includes(original), isTrue);
    },
  );
  test(
    'native adapter refuses reference intent without its declared section change',
    () async {
      final before = await bookFile.readAsString();
      final read = await store.open(original) as storage.Opened;
      final scope = GamesEdited(
        GamesWritten(rewritten: {0}),
        references: ReferenceChanges([
          SectionRename(path: original.path, from: 'A', to: 'B'),
        ]),
      );
      expect(
        await store.save(
          original,
          _course,
          expected: read.revision,
          scope: scope,
        ),
        isA<storage.SaveRefused>(),
      );
      expect(await File(original.path).readAsString(), _course);
      expect(await bookFile.readAsString(), before);
    },
  );

  test(
    'native adapter refuses a forged compound inverse even for a kept PGN',
    () async {
      final beforeBooks = await bookFile.readAsString();
      await library.renameChapter(original, 'B');
      final renamed = await store.open(original) as storage.Opened;
      final afterBooks = await bookFile.readAsString();
      final forged = CompoundCommit(
        id: 'invented',
        documentPath: original.path,
        documentBefore: _course,
        documentAfter: renamed.text,
        booksBefore: beforeBooks,
        booksAfter: afterBooks,
      );
      expect(
        await store.save(
          original,
          _course,
          expected: renamed.revision,
          scope: RestoredVersion(inverse: forged),
        ),
        isA<storage.RestoreRefused>(),
      );
      expect(await File(original.path).readAsString(), renamed.text);
      expect(await bookFile.readAsString(), afterBooks);
    },
  );
}
