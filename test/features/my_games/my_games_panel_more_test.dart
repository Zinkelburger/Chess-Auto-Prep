// The My games column, in the small: a first comparison that fails offers
// Try again rather than a spinner, the game on the board is the one marked
// in the list, a group of games is named by its newest, and another book
// handed to the column is the one watched.
import 'package:chess_auto_prep/features/my_games/game_book.dart';
import 'package:chess_auto_prep/features/my_games/my_games_panel.dart';
import 'package:chess_auto_prep/ui/list_row.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
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

  Future<void> panel(WidgetTester tester, BookFixture over) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: MyGamesPanel(
            book: over.book,
            session: session,
            accounts: const Text('accounts'),
            bookChip: const SizedBox.shrink(),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a first comparison that fails offers Try again', (tester) async {
    fixture.accounts.unavailable = true;
    await panel(tester, fixture);
    expect(fixture.book.state, isA<BookReading>());
    expect(find.text('Could not compare your games.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the game on the board is the one marked', (tester) async {
    await panel(tester, fixture);
    final checked = (fixture.book.state as BookChecked).games;
    final second = checked[1];
    await session.open(second.file, game: second.game.index);
    await tester.pumpAndSettle();
    final marked = [
      for (final row in tester.widgetList<ListRow>(find.byType(ListRow)))
        if (row.selected) row,
    ];
    expect(marked, hasLength(1));
  });

  testWidgets('a group of games that ended the book by transposition is named '
      'by its newest game', (tester) async {
    final transposed = BookFixture(
      games: [
        myGame(
          'game0001',
          '2026.09.19',
          '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4',
          white: false,
          result: '0-1',
        ),
        myGame(
          'game0002',
          '2026.09.20',
          '1. e4 c5 2. d4 cxd4 3. Nf3 d6 4. Nxd4',
          white: false,
          result: '0-1',
        ),
      ],
    );
    addTearDown(transposed.dispose);
    await panel(tester, transposed);
    await tester.tap(find.text('Openings'));
    await tester.pumpAndSettle();
    expect(find.text('Book ended (1)'), findsOneWidget);
    expect(find.text('2 games'), findsOneWidget);
    expect(find.text('after 3...d6'), findsOneWidget);
  });

  testWidgets('another book handed to it is the one watched', (tester) async {
    final other = BookFixture();
    addTearDown(other.dispose);
    await panel(tester, fixture);
    expect(other.accounts.snapshots, 0);
    await panel(tester, other);
    expect(other.accounts.snapshots, greaterThan(0));
    final before = fixture.accounts.snapshots;
    fixture.book.recheck();
    await tester.pumpAndSettle();
    expect(fixture.accounts.snapshots, before, reason: 'no longer watched');
  });
}
