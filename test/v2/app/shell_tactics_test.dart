import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/features/tactics/my_games.dart';
import 'package:chess_auto_prep/v2/workspace/comment_field.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/explorer_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/tactics_fixture.dart';
import '../support/window_fixture.dart';

/// Tactics in the window: the list in the left column, the puzzle on the
/// shared board, the Puzzle tab on the reading card.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> toTactics(WidgetTester tester) async {
    await w.pumpShell(tester);
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tactics'));
    await tester.pumpAndSettle();
  }

  testWidgets('the list shows what Play plays, and the filters change it', (
    tester,
  ) async {
    await toTactics(tester);
    expect(find.text('Play (4)'), findsOneWidget);
    expect(find.text('4 of 5'), findsOneWidget);
    expect(find.text('2 blunders, 1 mistake, 1 custom'), findsOneWidget);
    expect(find.text('1... f6?'), findsOneWidget);
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inaccuracies ?!'));
    await tester.pumpAndSettle();
    expect(find.text('Play (5)'), findsOneWidget);
    expect(w.settings.value.puzzles.kinds.length, 4);
  });

  testWidgets('play brings the Puzzle tab up over a hidden answer; Space '
      'shows it', (tester) async {
    await toTactics(tester);
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    expect(w.session.source, tacticsRef);
    expect(find.text('Black to play · 2 moves'), findsOneWidget);
    expect(find.text('Find the best move.'), findsOneWidget);
    expect(find.text('Puzzle 1 of 4'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Solution: e5 Nf3 Nc6'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('a puzzle clicked in the list comes up at once', (tester) async {
    await toTactics(tester);
    await tester.tap(find.text('4. Qe2??'));
    await tester.pumpAndSettle();
    expect(w.session.game, 0);
    expect(find.text('White to play'), findsOneWidget);
    // The board's move is judged, not written into the set.
    w.trainer.play('h5f7');
    await tester.pumpAndSettle();
    expect(find.text('Correct!'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(w.session.game, 1);
  });

  testWidgets('leaving Tactics puts the puzzle down: the board is the '
      'document\'s, and a solved puzzle brings up no next one', (tester) async {
    await toTactics(tester);
    await tester.tap(find.text('4. Qe2??'));
    await tester.pumpAndSettle();
    w.trainer.play('h5f7');
    await tester.pumpAndSettle();
    expect(find.text('Correct!'), findsOneWidget);
    w.requests.switchTo(Mode.repertoires);
    await tester.pumpAndSettle();
    expect(w.trainer.up, isNull);
    expect(w.trainer.run, isNotNull, reason: 'the run is kept for Tactics');
    expect(w.session.shownTo, isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(w.session.game, 0, reason: 'the next puzzle was not opened');
    expect(w.trainer.up, isNull);
  });

  testWidgets('Tactics shows the puzzle and its game only; the engine and '
      'the arrows wait for the answer, and Analyze opens the game', (
    tester,
  ) async {
    await toTactics(tester);
    expect(find.text('Puzzle'), findsOneWidget);
    expect(find.text('Game'), findsOneWidget);
    for (final builder in ['Train', 'Replies', 'Explorer', 'Moves']) {
      expect(find.text(builder), findsNothing, reason: builder);
    }
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Toggle engine (E)'), findsNothing);
    expect(find.byTooltip('Previous puzzle (↑)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(
      w.analysis.state,
      isNot(isA<EngineFailed>()),
      reason: 'E is not heard while the answer is hidden',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Toggle engine (E)'), findsOneWidget);
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();
    expect(w.analysis.state, isA<EngineFailed>(), reason: 'it was asked');
    expect(find.text('Solution: e5 Nf3 Nc6'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(w.trainer.up?.puzzle.index, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(w.trainer.up?.puzzle.index, 1);
    expect(w.trainer.up?.finished, isFalse);
  });

  testWidgets('Ctrl+E does not open the edit strip over a hidden answer', (
    tester,
  ) async {
    await toTactics(tester);
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    // The answer shown, nothing is hidden any more: the strip would be up
    // now had the key opened it.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Solution: e5 Nf3 Nc6'), findsOneWidget);
    expect(find.byType(CommentField), findsNothing);
  });

  testWidgets('the Explorer tab is empty while the answer is hidden', (
    tester,
  ) async {
    await toTactics(tester);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SubmenuButton, 'Panels'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Show Explorer'));
    await tester.tap(find.text('Show Explorer'));
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerPane), findsOneWidget);
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explorer'));
    await tester.pumpAndSettle();
    expect(
      find.byType(ExplorerPane),
      findsNothing,
      reason:
          'it would tick '
          'the answer',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerPane), findsOneWidget);
  });

  testWidgets('Ctrl+G starts no search in Tactics, which has no Search tab '
      'to show it in', (tester) async {
    await toTactics(tester);
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(w.session.shownTo, isNull, reason: 'a search could start here');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(w.fill.running, isFalse);
    expect(w.analysis.paused, isFalse);
  });

  testWidgets('with no username the column asks for one; saving it offers '
      'Get my games and downloads nothing', (tester) async {
    await toTactics(tester);
    expect(find.text('Get games'), findsNothing);
    await tester.tap(find.text('Add accounts'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Lichess username'),
      'Me',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(w.accounts.accounts[GameSite.lichess]?.username, 'Me');
    expect(find.text('Me'), findsOneWidget);
    expect(find.text('Get games'), findsOneWidget);
    expect(w.myGames.status, isA<MyGamesIdle>());
  });
}
