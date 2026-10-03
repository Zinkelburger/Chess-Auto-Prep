import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/features/tactics/puzzle_pane.dart';
import 'package:chess_auto_prep/workspace/comment_field.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/study_choice.dart';
import 'package:chess_auto_prep/workspace/explorer_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_input.dart';
import '../support/scripted_store.dart';
import '../support/study_fixture.dart' show studiesRoot;
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

  testWidgets('Play uses the searched puzzles and zero results disable it', (
    tester,
  ) async {
    await toTactics(tester);
    final search = find.descendant(
      of: find.byTooltip('Search'),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'no such opponent');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Play (0)'))
          .onPressed,
      isNull,
    );
    await tester.enterText(search, 'Rival');
    await tester.pumpAndSettle();
    final expected = w.tactics.queue.map((p) => p.fen).toList();
    expect(expected, isNotEmpty);
    await tester.tap(find.text('Play (${expected.length})'));
    await tester.pumpAndSettle();
    expect(w.parts.training.puzzles.run!.queue, expected);
  });

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
    expect(find.byTooltip('Turn engine off (E)'), findsNothing);
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
    expect(
      find.byTooltip('Turn engine off (E)'),
      findsNothing,
      reason: 'off stays collapsed after revealing the answer',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(PuzzlePane),
        matching: find.text('Analyze'),
      ),
    );
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
    await tester.tap(find.widgetWithText(SubmenuButton, 'Action Tabs'));
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

  group('a puzzle\'s game', () {
    const moves = '1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qe2 Nd4 5. Qd1';
    final withSource = tacticsSet.replaceFirst(
      '[FlawTags "opening hasty"]',
      '[FlawTags "opening hasty"]\n[SourceMovetext "$moves"]',
    );

    testWidgets('the Game tab shows it at the puzzle\'s move, and Analyze '
        'game opens it on a board there', (tester) async {
      w.store.documents[tacticsRef] = Opened(
        withSource,
        scriptedRevision(withSource),
      );
      await toTactics(tester);
      await tester.tap(find.text('Game'));
      await tester.pumpAndSettle();
      expect(find.text('Play a puzzle to see its game.'), findsOneWidget);
      await tester.tap(find.text('4. Qe2??'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Game'));
      await tester.pumpAndSettle();
      expect(find.text('Me – Rival'), findsOneWidget);
      expect(find.text('4.Qe2??'), findsOneWidget);
      final puzzle = w.trainer.up!.puzzle;
      await tester.tap(find.text('Analyze game'));
      await tester.pumpAndSettle();
      expect(w.session.isScratch, isTrue);
      expect(w.session.fen.position, puzzle.fen.position);
      expect(find.text('Moves'), findsOneWidget);
    });

    testWidgets('the row menu and Actions add the puzzle\'s game, not the '
        'board, to a study, named by its players', (tester) async {
      final input = ScriptedInput()
        ..study = (into: const NewStudy('Puzzles'), name: 'Me – Rival');
      w.dispose();
      w = WindowFixture(input: input);
      w.store.documents[tacticsRef] = Opened(
        withSource,
        scriptedRevision(withSource),
      );
      await toTactics(tester);
      final puzzle = w.tactics.at(0)!;
      final row = find
          .ancestor(of: find.text(puzzle.label), matching: find.byType(InkWell))
          .first;
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Puzzle actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add game to study…'));
      await tester.pumpAndSettle();
      final study = ChapterRef.at('$studiesRoot/Puzzles.pgn');
      final added = (w.store.documents[study]! as Opened).text;
      expect(input.chaptersAsked, ['Me – Rival']);
      expect(added, contains('4. Qe2 Nd4 5. Qd1'));

      await tester.tap(find.text(puzzle.label));
      await tester.pumpAndSettle();
      expect(w.trainer.up?.puzzle.fen, puzzle.fen);
      input.study = (into: IntoStudy(study), name: 'Me – Rival');
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add game to study…'));
      await tester.pumpAndSettle();
      expect(input.chaptersAsked, ['Me – Rival', 'Me – Rival']);
      final twice = (w.store.documents[study]! as Opened).text;
      expect('4. Qe2 Nd4 5. Qd1'.allMatches(twice), hasLength(2));
      expect(twice, isNot(contains('4. Qxf7#')));
    });

    testWidgets('a puzzle row copies its position and can be deleted', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await toTactics(tester);
      await tester.tap(find.byTooltip('Puzzle actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy FEN'));
      await tester.pumpAndSettle();
      expect(copied.single, w.tactics.queue.first.fen.value);
      final doomed = w.tactics.queue.first;
      await tester.tap(find.byTooltip('Puzzle actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete puzzle…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Play (3)'), findsOneWidget);
      expect(
        (w.store.documents[tacticsRef]! as Opened).text,
        isNot(contains(doomed.fen.value)),
      );
    });
  });
}
