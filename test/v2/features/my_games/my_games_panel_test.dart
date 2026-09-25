import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/features/my_games/game_book.dart';
import 'package:chess_auto_prep/v2/features/my_games/my_games_panel.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
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
        bookChip: const SizedBox.shrink(),
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

  testWidgets('the search is the book\'s, so the column built again still '
      'shows it', (tester) async {
    await pumpPanel(tester);
    await tester.enterText(find.byType(TextField), 'NC3');
    await tester.pumpAndSettle();
    expect(fixture.book.query, 'nc3');
    expect(fixture.book.shown, hasLength(2));
    await pump(tester, const SizedBox.shrink());
    await pumpPanel(tester);
    expect(find.text('2 of 5 games'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'nc3'), findsOneWidget);
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
  testWidgets(
    'failed refresh labels retained games and Retry restores current actions',
    (tester) async {
      await pumpPanel(tester);
      final original = fixture.store.documents[fixture.gamesRef]!;
      fixture.store.documents[fixture.gamesRef] = const Unreadable(
        'offline corpus',
      );
      fixture.book.recheck();
      await tester.pumpAndSettle();
      expect(find.text('Previous comparison'), findsOneWidget);
      expect(find.textContaining('offline corpus'), findsOneWidget);
      expect(find.text('5 games, newest first'), findsOneWidget);
      await tester.tap(
        find.text('2...Nc6 not in book', findRichText: true),
        warnIfMissed: false,
      );
      expect(opened, isEmpty);
      fixture.store.documents[fixture.gamesRef] = original;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Previous comparison'), findsNothing);
      expect(find.textContaining('offline corpus'), findsNothing);
      await tester.tap(find.text('2...Nc6 not in book', findRichText: true));
      expect(opened, hasLength(1));
    },
  );

  for (final openings in [false, true]) {
    testWidgets(
      'focused ${openings ? 'opening' : 'game'} refuses stale keys until Retry',
      (tester) async {
        await pumpPanel(tester);
        if (openings) {
          await tester.tap(find.text('Openings'));
          await tester.pumpAndSettle();
        }
        final control = openings
            ? find.text('2.Nc3')
            : find.text('2...Nc6 not in book', findRichText: true);
        await _tabTo(tester, control);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(opened, hasLength(1));
        final date = opened.single.game.date;
        opened.clear();
        // Account publication can precede the next frame. The callback must
        // consult current provenance even while its retained row has focus.
        await fixture.accounts.setUsername(GameSite.lichess, 'Another');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(opened, isEmpty);
        await fixture.accounts.setUsername(GameSite.lichess, 'Me');
        final original = fixture.store.documents[fixture.gamesRef]!;
        fixture.store.documents[fixture.gamesRef] = const Unreadable(
          'offline corpus',
        );
        fixture.book.recheck();
        await tester.pumpAndSettle();
        expect(find.text('Previous comparison'), findsOneWidget);
        expect(find.textContaining('offline corpus'), findsOneWidget);
        expect(control, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(opened, isEmpty);
        fixture.store.documents[fixture.gamesRef] = original;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Previous comparison'), findsNothing);
        await _tabTo(tester, control);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(opened, hasLength(1));
        expect(opened.single.game.date, date);
      },
    );
  }
}

/// Reach the actual control through keyboard traversal, then exercise its
/// normal shortcuts; no widget callback is invoked directly by the test.
Future<void> _tabTo(WidgetTester tester, Finder control) async {
  for (var step = 0; step < 20; step++) {
    if (Focus.of(tester.element(control)).hasFocus) return;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail('Keyboard traversal did not reach $control');
}
