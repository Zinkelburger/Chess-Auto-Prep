import 'dart:async';

import 'package:chess_auto_prep/v2/features/books/books_screen.dart';
import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/book_chip.dart';
import 'package:chess_auto_prep/v2/workspace/books.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/status_host.dart';

const saved = Saved(
  Receipt(
    committed: Revision('after0000'),
    before: '',
    beforeRevision: Revision('before000'),
  ),
);

void main() {
  late _BooksFile store;
  late Books books;
  late RepertoireCatalog catalog;

  setUp(() {
    store = _BooksFile(
      const BookList(
        books: [Book(id: 'b', name: 'Event')],
      ),
    );
    books = Books(store: store, root: '/repertoires');
    catalog = RepertoireCatalog(
      files: ScriptedFiles(
        listing: Repertoires([
          folder('Course', ['Main']),
        ]),
      ),
      root: '/repertoires',
    );
  });
  tearDown(() {
    books.dispose();
    catalog.dispose();
  });

  Future<void> show(WidgetTester tester, {bool chip = false}) async {
    await books.load();
    await catalog.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: chip
                ? Align(
                    alignment: Alignment.topLeft,
                    child: BookChip(books: books, onEdit: () {}),
                  )
                : BooksScreen(
                    books: books,
                    catalog: catalog,
                    onOpenChapter: (_) {},
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'reference save shows status and disables book mutation controls',
    (tester) async {
      await show(tester);
      final held = Completer<SaveResult>();
      final saving = books.saveReferences(() => held.future);
      await tester.pump();
      expect(find.text('Updating book chapters…'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'New book'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Use this book'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).onChanged,
        isNull,
      );
      held.complete(saved);
      await saving;
      await tester.pumpAndSettle();
      expect(find.text('Updating book chapters…'), findsNothing);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(books.books.single.repertoires, {'Course'});
    },
  );

  testWidgets(
    'creation already confirmed in a dialog waits for reference save',
    (tester) async {
      await show(tester);
      await tester.tap(find.widgetWithText(TextButton, 'New book'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Next event');
      final held = Completer<SaveResult>();
      final saving = books.saveReferences(() => held.future);
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(books.books, hasLength(1));
      held.complete(saved);
      await saving;
      await tester.pumpAndSettle();
      expect(books.books.map((book) => book.name), contains('Next event'));
    },
  );

  testWidgets('rename dialog waits and uses the newly committed selectors', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Renamed');
    final held = Completer<SaveResult>();
    final saving = books.saveReferences(() => held.future);
    await tester.pump();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(books.books.single.name, 'Event');
    store.books = BookList(
      books: [
        Book(
          id: 'b',
          name: 'Event',
          chapters: {BookChapter('Course/Main.pgn', 'New section')},
        ),
      ],
    );
    held.complete(saved);
    await saving;
    await tester.pumpAndSettle();
    expect(books.books.single.name, 'Renamed');
    expect(books.books.single.chapters, {
      const BookChapter('Course/Main.pgn', 'New section'),
    });
  });

  testWidgets('book chip shows reference status and disables choosing', (
    tester,
  ) async {
    await show(tester, chip: true);
    final held = Completer<SaveResult>();
    final saving = books.saveReferences(() => held.future);
    await tester.pump();
    expect(find.text('Updating book chapters…'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
    held.complete(saved);
    await saving;
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('an already open book choice waits before activating', (
    tester,
  ) async {
    await show(tester, chip: true);
    await tester.tap(find.text('No book set'));
    await tester.pumpAndSettle();
    final held = Completer<SaveResult>();
    final saving = books.saveReferences(() => held.future);
    await tester.pump();
    await tester.tap(find.text('Event'));
    await tester.pumpAndSettle();
    expect(books.active, isNull);
    held.complete(saved);
    await saving;
    await tester.pumpAndSettle();
    expect(books.active?.id, 'b');
  });

  testWidgets('a queued choice explains when books could not recover', (
    tester,
  ) async {
    await show(tester, chip: true);
    await tester.tap(find.text('No book set'));
    await tester.pumpAndSettle();
    final held = Completer<SaveResult>();
    final saving = books.saveReferences(() => held.future);
    await tester.pump();
    await tester.tap(find.text('Event'));
    await tester.pumpAndSettle();
    store.failReads = true;
    held.complete(saved);
    await saving;
    await tester.pumpAndSettle();
    expect(books.active, isNull);
    expect(find.text(books.problem!), findsOneWidget);
  });

  testWidgets('an already open delete confirmation waits before deleting', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    final held = Completer<SaveResult>();
    final saving = books.saveReferences(() => held.future);
    await tester.pump();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(books.books, hasLength(1));
    held.complete(saved);
    await saving;
    await tester.pumpAndSettle();
    expect(books.books, isEmpty);
  });
}

class _BooksFile implements BookStore {
  _BooksFile(this.books);

  BookList books;
  bool failReads = false;

  @override
  Future<BookList> read() async {
    if (failReads) throw StateError('Recovery still pending');
    return books;
  }

  @override
  Future<void> write(BookList books) async => this.books = books;
}
