// The Books screen's lists: which book is in use and which is open, the
// repertoires with their boxes and their chapters, the search over both,
// and what it says when there is nothing to list.
import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/features/books/books_screen.dart';
import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/book_snapshot.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/list_row.dart';
import 'package:chess_auto_prep/ui/search_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/book/books.dart';
import 'package:chess_auto_prep/workspace/book/repertoire_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/status_host.dart';

final class _BooksFile implements BookStore {
  _BooksFile(this.books);

  BookList books;

  @override
  Future<BookList> read() async => books;

  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: books);

  @override
  Future<BookSnapshot> write(BookList books) async {
    this.books = books;
    return BookSnapshot(value: books);
  }
}

void main() {
  late Books books;
  late RepertoireCatalog catalog;

  /// Course (Main, Sideline and a draft) and Openings (Najdorf).
  final course = RepertoireFolder(
    name: 'Course',
    path: '/repertoires/Course',
    modified: DateTime(2026),
    chapters: [
      ref('Course', 'Main'),
      ref('Course', 'Sideline'),
      const ChapterRef(
        repertoire: 'Course',
        name: 'Proposed',
        path: '/repertoires/Course/Proposed.pgn',
        heading: ChapterHeading(draft: true),
      ),
    ],
  );
  final openings = folder('Openings', ['Najdorf']);

  void start({List<RepertoireFolder>? repertoires}) {
    books = Books(
      store: _BooksFile(
        const BookList(
          books: [
            Book(id: 'b', name: 'Event'),
            Book(id: 'c', name: 'Club'),
          ],
          active: 'b',
        ),
      ),
      root: '/repertoires',
    );
    catalog = RepertoireCatalog(
      files: ScriptedFiles(
        listing: Repertoires(repertoires ?? [course, openings]),
      ),
      root: '/repertoires',
    );
    addTearDown(() {
      books.dispose();
      catalog.dispose();
    });
  }

  Future<void> show(
    WidgetTester tester, {
    bool load = true,
    VoidCallback? onAddRepertoire,
  }) async {
    if (load) {
      await books.load();
      await catalog.refresh();
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: BooksScreen(
              books: books,
              catalog: catalog,
              onOpenChapter: (_) {},
              onAddRepertoire: onAddRepertoire,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Book named(String name) => books.books.singleWhere((b) => b.name == name);

  Future<void> search(WidgetTester tester, String words) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(SearchField),
        matching: find.byType(TextField),
      ),
      words,
    );
    await tester.pumpAndSettle();
  }

  bool? box(WidgetTester tester, String row) => tester
      .widget<Checkbox>(
        find.descendant(
          of: find.ancestor(of: find.text(row), matching: find.byType(ListRow)),
          matching: find.byType(Checkbox),
        ),
      )
      .value;

  testWidgets('says so while the books are read', (tester) async {
    start();
    await show(tester, load: false);
    expect(find.text('Reading opening books…'), findsOneWidget);
  });

  testWidgets('marks the book in use, and the one open', (tester) async {
    start();
    await show(tester);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Club'),
          matching: find.byType(ListRow),
        ),
        matching: find.text('In use'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Event'),
          matching: find.byType(ListRow),
        ),
        matching: find.text('In use'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();
    ListRow row(String name) => tester.widget<ListRow>(
      find.ancestor(of: find.text(name), matching: find.byType(ListRow)).first,
    );
    expect(row('Club').selected, isTrue);
    expect(row('Event').selected, isFalse);
  });

  testWidgets('a repertoire the book has in part starts open, part-ticked; '
      'one it has none of starts shut and unticked; drafts are not offered', (
    tester,
  ) async {
    start();
    await books.load();
    books.setChapter(named('Event'), course, course.chapters.first, true);
    await show(tester);
    expect(box(tester, 'Course'), isNull);
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('Sideline'), findsOneWidget);
    expect(find.text('Proposed'), findsNothing);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(box(tester, 'Openings'), isFalse);
    expect(find.text('Najdorf'), findsNothing);
  });

  testWidgets('a chapter is ticked from its row or its box', (tester) async {
    start();
    await show(tester);
    await tester.tap(find.text('Openings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Najdorf'));
    await tester.pumpAndSettle();
    expect(books.contains(named('Event'), openings.chapters.single), isTrue);
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Najdorf'),
          matching: find.byType(ListRow),
        ),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    expect(books.contains(named('Event'), openings.chapters.single), isFalse);
  });

  testWidgets('while chapters are being saved, no box can be ticked', (
    tester,
  ) async {
    start();
    await show(tester);
    await tester.tap(find.text('Openings'));
    await tester.pumpAndSettle();
    final held = Completer<SaveResult>();
    final saving = books.saveReferences(() => held.future);
    await tester.pump();
    final chapterBox = tester.widget<Checkbox>(
      find.descendant(
        of: find.ancestor(
          of: find.text('Najdorf'),
          matching: find.byType(ListRow),
        ),
        matching: find.byType(Checkbox),
      ),
    );
    expect(chapterBox.onChanged, isNull);
    held.complete(
      const Saved(
        Receipt(
          committed: Revision('after0000'),
          before: '',
          beforeRevision: Revision('before000'),
        ),
      ),
    );
    await saving;
    await tester.pumpAndSettle();
  });

  group('the search', () {
    testWidgets('by a repertoire\'s name lists it alone, shut', (tester) async {
      start();
      await show(tester);
      await search(tester, 'cour');
      expect(find.text('Course'), findsOneWidget);
      expect(find.text('Openings'), findsNothing);
      expect(find.text('Main'), findsNothing);
    });

    testWidgets('by a chapter\'s name lists its repertoire open at it', (
      tester,
    ) async {
      start();
      await show(tester);
      await search(tester, 'najd');
      expect(find.text('Openings'), findsOneWidget);
      expect(find.text('Najdorf'), findsOneWidget);
      expect(find.text('Course'), findsNothing);
    });

    testWidgets('matching nothing says so, and offers no builder', (
      tester,
    ) async {
      start();
      await show(tester, onAddRepertoire: () {});
      await search(tester, 'grob');
      expect(find.text('Nothing matches "grob".'), findsOneWidget);
      expect(find.text('Open repertoire builder'), findsNothing);
    });
  });

  testWidgets('with no repertoires, says how to make one and offers the '
      'builder', (tester) async {
    start(repertoires: const []);
    await show(tester, onAddRepertoire: () {});
    expect(
      find.text(
        'Create or import a repertoire, then choose its chapters for this '
        'book.',
      ),
      findsOneWidget,
    );
    expect(find.text('Open repertoire builder'), findsOneWidget);
  });

  testWidgets('a new book is made without a word', (tester) async {
    start();
    await show(tester);
    await tester.tap(find.byTooltip('New opening book…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Next event');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(books.books.map((b) => b.name), contains('Next event'));
    expect(find.text('Could not make the book.'), findsNothing);
  });
}
