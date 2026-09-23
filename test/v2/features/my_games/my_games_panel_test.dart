import 'package:chess_auto_prep/v2/chess/book/book_check.dart';
import 'package:chess_auto_prep/v2/features/my_games/book_pane.dart';
import 'package:chess_auto_prep/v2/features/my_games/game_book.dart';
import 'package:chess_auto_prep/v2/features/my_games/my_games_panel.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/book_fixture.dart';

void main() {
  late BookFixture fixture;
  late DocumentSaver saver;
  late DocumentSession session;

  setUp(() {
    fixture = BookFixture();
    saver = DocumentSaver(fixture.store, delay: Duration.zero);
    session = DocumentSession(fixture.store, saver);
  });

  tearDown(() {
    fixture.dispose();
    session.dispose();
    saver.dispose();
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the column', () {
    late List<CheckedGame> opened;

    Future<void> pumpPanel(WidgetTester tester) {
      opened = [];
      return pump(
        tester,
        MyGamesPanel(
          book: fixture.book,
          session: session,
          accounts: const Text('accounts'),
          onOpen: opened.add,
        ),
      );
    }

    testWidgets('lists the games newest first with their verdicts', (
      tester,
    ) async {
      await pumpPanel(tester);
      expect(find.text('accounts'), findsOneWidget);
      expect(find.text('5 games, newest first'), findsOneWidget);
      expect(find.text('You left book: 2.Nc3 (book 2.Nf3)'), findsNWidgets(2));
      expect(find.text('Book ended after 3...cxd4'), findsOneWidget);
      expect(find.text('vs Rival (2105) · Won · 2026.09.21'), findsOneWidget);
      await tester.tap(find.text('Not in your book: 2...Nc6'));
      expect(opened.single.game.date, '2026.09.21');
    });

    testWidgets('the search narrows by opponent, date or verdict', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.enterText(find.byType(TextField), 'nc3');
      await tester.pumpAndSettle();
      expect(find.text('2 of 5 games'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'nobody');
      await tester.pumpAndSettle();
      expect(find.text('Nothing matches "nobody".'), findsOneWidget);
    });

    testWidgets('Openings groups the ways the games left the book', (
      tester,
    ) async {
      await pumpPanel(tester);
      await tester.tap(find.text('Openings'));
      await tester.pumpAndSettle();
      expect(find.text('You left book (1)'), findsOneWidget);
      expect(find.text('Not in your book (1)'), findsOneWidget);
      expect(find.text('Book ended (1)'), findsOneWidget);
      expect(find.text('2 games'), findsOneWidget);
      expect(find.text('Book 2.Nf3 · Sicilian'), findsOneWidget);
      expect(find.text('after 3...cxd4'), findsOneWidget);
      await tester.tap(find.text('2.Nc3'));
      // The newest game of the group.
      expect(opened.single.game.date, '2026.09.20');
    });

    testWidgets('says what is missing before there is anything to list', (
      tester,
    ) async {
      fixture.saveGames([]);
      await pumpPanel(tester);
      expect(
        find.text('No games saved yet. Get games above to download them.'),
        findsOneWidget,
      );
    });
  });

  group('the Book tab', () {
    late List<BookPlace> read;

    Future<void> pumpPane(WidgetTester tester, int game) async {
      read = [];
      await session.open(fixture.gamesFile, game: game);
      await pump(
        tester,
        BookPane(book: fixture.book, session: session, onReadBook: read.add),
      );
    }

    testWidgets('sets the move played beside what the book plays', (
      tester,
    ) async {
      await pumpPane(tester, 3);
      expect(find.text('You left book: 2.Nc3 (book 2.Nf3)'), findsOneWidget);
      expect(find.text('vs Rival (2105) · Lost · 2026.09.20'), findsOneWidget);
      expect(find.text('2.Nc3'), findsOneWidget);
      expect(find.text('2.Nf3'), findsOneWidget);
      expect(find.text('2 lines'), findsOneWidget);
      expect(find.text('2...d6 3.d4'), findsOneWidget);
    });

    testWidgets('goes back to the move, and into the book where it left', (
      tester,
    ) async {
      await pumpPane(tester, 3);
      session.toEnd();
      await tester.tap(find.text('Show the move'));
      expect(session.cursor.indexes, [0, 0, 0]);
      await tester.tap(find.text('Open in builder'));
      expect(read.single.file.path, sicilianRef.path);
      expect(read.single.sans, ['e4', 'c5']);
      await tester.tap(find.text('Sicilian'));
      expect(read.last.sans, ['e4', 'c5', 'Nf3']);
    });

    testWidgets('a game in another opening says it is not a mistake', (
      tester,
    ) async {
      await pumpPane(tester, 0);
      expect(find.text('Another opening'), findsOneWidget);
      expect(find.textContaining('not a mistake'), findsOneWidget);
      expect(find.text('Open in builder'), findsNothing);
    });

    testWidgets('a document that is not one of the games asks for one', (
      tester,
    ) async {
      await session.open(sicilianRef);
      await pump(
        tester,
        BookPane(book: fixture.book, session: session, onReadBook: (_) {}),
      );
      expect(find.textContaining('Open one of your games'), findsOneWidget);
    });
  });
}
