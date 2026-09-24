import 'dart:async';

import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/features/books/books_screen.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';
import '../support/scripted_files.dart';

/// Books in the window: the mode that edits them, the pencil beside the
/// book wherever it is read, and Back to where the user came from.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Finder inLibrary(Finder row) =>
      find.descendant(of: find.byType(LibraryPanel), matching: row);

  Future<void> toMode(WidgetTester tester, String label) async {
    await tester.tap(find.text(w.requests.mode.label).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('the Books mode lists the books and ticks a repertoire out', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await toMode(tester, 'Books');
    expect(w.requests.mode, Mode.books);
    expect(find.byType(BooksScreen), findsOneWidget);
    expect(find.text('In use'), findsWidgets);
    expect(find.text('benko'), findsOneWidget);
    expect(find.text('KID'), findsOneWidget);
    expect(w.parts.books.includes(kidMain), isTrue);
    // The KID row's box takes the whole repertoire out.
    final kidRow = find.ancestor(
      of: find.text('KID'),
      matching: find.byType(InkWell),
    );
    await tester.tap(
      find.descendant(of: kidRow.first, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(w.parts.books.includes(kidMain), isFalse);
    expect(w.parts.books.includes(benkoMain), isTrue);
  });

  testWidgets(
    'removing a repertoire unticks an explicitly selected nested chapter',
    (tester) async {
      final nested = ref('KID/Classical', 'Main');
      final kid = RepertoireFolder(
        name: 'KID',
        path: '/repertoires/KID',
        modified: DateTime(2026),
        chapters: [nested],
      );
      w.chapterFiles.listing = Repertoires([
        folder('benko', ['Main']),
        kid,
      ]);
      await w.pumpShell(tester);
      final books = w.parts.books;
      books.setRepertoire(books.active!, kid, false);
      books.setChapter(books.active!, kid, nested, true);
      await toMode(tester, 'Books');
      expect(books.includes(nested), isTrue);
      final kidRow = find.ancestor(
        of: find.text('KID'),
        matching: find.byType(InkWell),
      );
      await tester.tap(
        find.descendant(of: kidRow.first, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(books.includes(nested), isFalse);
      expect(books.includes(benkoMain), isTrue);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: kidRow.first,
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        isFalse,
      );
    },
  );

  testWidgets('the explorer\'s Book shows the book in use, and its pencil '
      'goes to Books; Back comes back', (tester) async {
    await w.pumpShell(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explorer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book').first);
    await tester.pumpAndSettle();
    expect(find.text('Test book'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit books'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.books);
    expect(w.requests.backTo?.mode, Mode.repertoires);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.repertoires);
    expect(w.session.source, kidMain);
    expect(w.requests.forwardTo?.mode, Mode.books);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.books);
  });

  testWidgets('Back returns to the file and position a jump left', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    w.session.forward();
    await tester.pumpAndSettle();
    final at = w.session.cursor;
    await toMode(tester, 'My games');
    unawaited(w.requests.readInBuilder(benkoMain, const []));
    await tester.pumpAndSettle();
    expect(w.session.source, benkoMain);
    unawaited(w.requests.back());
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.myGames);
    unawaited(w.requests.back());
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.repertoires);
    expect(w.session.source, kidMain);
    expect(w.session.cursor, at);
  });
}
