import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/book_fixture.dart' show myGame;
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

/// My games in the window: the user's games in the left column, each game
/// on the shared board from their side, the Book tab on the reading card,
/// and the way into the builder where a game left the book.
void main() {
  late WindowFixture w;

  /// Two of "Me"'s games as Black against the KID chapter of the fixture,
  /// which is a Sicilian from 1.e4: one past its end, one leaving it at 2...e6.
  final games = [
    myGame(
      'game0001',
      '2026.09.20',
      '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4',
      white: false,
    ),
    myGame('game0002', '2026.09.21', '1. e4 c5 2. Nf3 e6', white: false),
  ];

  setUp(() {
    w = WindowFixture();
    w.accounts.accounts[GameSite.lichess] = const Account('Me');
    final text = '${games.join('\n\n')}\n';
    w.store.documents[w.gamesCache.refFor(GameSite.lichess, 'Me')] = Opened(
      text,
      scriptedRevision(text),
    );
  });
  tearDown(() => w.dispose());

  Future<void> toMyGames(WidgetTester tester) async {
    await w.pumpShell(tester);
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My games'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the games with their verdicts beside the Book tab', (
    tester,
  ) async {
    await toMyGames(tester);
    expect(w.requests.mode, Mode.myGames);
    expect(find.text('2...e6 left book', findRichText: true), findsOneWidget);
    expect(
      find.text('3...cxd4 book ended', findRichText: true),
      findsOneWidget,
    );
    for (final tab in ['Book', 'Game', 'Tree']) {
      expect(find.text(tab), findsOneWidget, reason: tab);
    }
    expect(find.textContaining('Open one of your games'), findsOneWidget);
  });

  testWidgets('a game opens from the user\'s side at the move that left the '
      'book, and the arrows walk the list', (tester) async {
    await toMyGames(tester);
    await tester.tap(find.text('2...e6 left book', findRichText: true));
    await tester.pumpAndSettle();
    expect(w.session.game, 1);
    expect(w.session.orientation, Side.black);
    expect(w.session.cursor.indexes, hasLength(4));
    expect(find.text('Played'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(w.session.game, 0);
    expect(w.session.cursor.indexes, hasLength(6));
  });

  testWidgets('the arrows walk only the games the search finds', (
    tester,
  ) async {
    await toMyGames(tester);
    w.book.search('09.21');
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 games'), findsOneWidget);
    await tester.tap(find.text('2...e6 left book', findRichText: true));
    await tester.pumpAndSettle();
    expect(w.session.game, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(w.session.game, 1, reason: 'the other game is not in the list');
  });

  testWidgets('Open in builder reads the book where the game left it', (
    tester,
  ) async {
    await toMyGames(tester);
    await tester.tap(find.text('3...cxd4 book ended', findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in builder'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.repertoires);
    expect(w.session.source, kidMain);
    expect(w.session.currentMove?.san, 'cxd4');
  });
}
