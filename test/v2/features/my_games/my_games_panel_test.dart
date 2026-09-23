import 'package:chess_auto_prep/v2/features/my_games/game_book.dart';
import 'package:chess_auto_prep/v2/features/my_games/my_games_panel.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/book_fixture.dart';

/// The My games column over a real [GameBook] on scripted files: the games
/// with their verdicts, the search and the Openings view.
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
    expect(find.text('2.Nc3 left book', findRichText: true), findsNWidgets(2));
    expect(
      find.text('3...cxd4 book ended', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('vs Rival (2105) · Won · 2026.09.21'), findsOneWidget);
    await tester.tap(find.text('2...Nc6 not in book', findRichText: true));
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
}
