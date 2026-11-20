import 'package:chess_auto_prep/features/tactics/puzzle_pane.dart';
import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_fixture.dart';

/// The Puzzle tab over the app's own trainer, with the set the window
/// fixture holds: #1 (Black, `1... f6?`, two moves to find) comes first,
/// then #0 (White, mate in one).
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  var analyzed = 0;

  Future<void> pumpPane(WidgetTester tester, {int available = 0}) async {
    analyzed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: PuzzlePane(
            trainer: w.trainer,
            available: available,
            onAnalyze: () => analyzed++,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> begin(WidgetTester tester) async {
    await w.tactics.load();
    await w.trainer.start();
    await tester.pump();
  }

  bool enabled(WidgetTester tester, String label) {
    final button = find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    return tester.widget<ButtonStyleButton>(button.first).onPressed != null;
  }

  testWidgets('with no sitting it says how many puzzles are ready, and '
      'nothing when there are none', (tester) async {
    await pumpPane(tester);
    expect(find.textContaining('ready to play'), findsNothing);
    await pumpPane(tester, available: 1);
    expect(find.text('1 puzzle ready to play.'), findsOneWidget);
    await pumpPane(tester, available: 3);
    expect(find.text('3 puzzles ready to play.'), findsOneWidget);
  });

  testWidgets('a puzzle says whose move it is, how many moves to find, and '
      'what was played; the cost waits for the answer', (tester) async {
    await pumpPane(tester);
    await begin(tester);
    expect(find.text('Black to play · 2 moves'), findsOneWidget);
    final date = w.trainer.up!.puzzle.date;
    expect(date, isNotEmpty);
    expect(find.text('vs Other · $date'), findsOneWidget);
    expect(find.text('You played f6 (mistake)', findRichText: true), findsOne);
    expect(find.textContaining('allowing', findRichText: true), findsNothing);
    expect(find.text('Find the best move.'), findsOneWidget);
    expect(find.text('Puzzle 1 of 4'), findsOneWidget);
    expect(enabled(tester, 'Show solution'), isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Try it again from the start'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
      reason: 'nothing to take back yet',
    );
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Rate'), findsNothing, reason: 'not before the answer');

    await tester.tap(find.text('Show solution'));
    await tester.pump();
    expect(find.text('Solution: e5 Nf3 Nc6', findRichText: true), findsOne);
    expect(
      find.text(
        'You played f6 (mistake), allowing d4   +0.3 → -1.1',
        findRichText: true,
      ),
      findsOne,
    );
    expect(find.text('Next'), findsOneWidget, reason: 'Skip reads Next');
    expect(find.text('Show solution'), findsNothing);
    await tester.tap(find.text('Analyze'));
    expect(analyzed, 1);
  });

  testWidgets('a wrong move and a right one each say so, and the progress '
      'line counts them', (tester) async {
    await pumpPane(tester);
    await begin(tester);
    w.trainer.play('a7a6');
    await tester.pump();
    expect(find.text('Incorrect — a6 is not it.'), findsOneWidget);
    expect(find.text('Puzzle 1 of 4 · 1 failed'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget, reason: 'the attempt counted');
    await tester.tap(find.byTooltip('Try it again from the start'));
    await tester.pump();
    expect(find.text('Find the best move.'), findsOneWidget);

    w.trainer.play('e7e5');
    await tester.pump();
    expect(find.text('Correct! (1/2)'), findsOneWidget);
    // The reply, then the second move: solved after the wrong try.
    await tester.pump(const Duration(seconds: 2));
    w.trainer.play('b8c6');
    await tester.pump();
    expect(find.text('Solved, after a wrong try.'), findsOneWidget);
    // After a solve the next puzzle comes by itself.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('White to play'), findsOneWidget, reason: 'one move');
    w.trainer.play('h5f7');
    await tester.pump();
    expect(find.text('Correct!'), findsOneWidget);
    expect(find.text('Puzzle 2 of 4 · 1 solved · 1 failed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the stars rate a puzzle on view; one hides it, and the star '
      'it has takes the rating away', (tester) async {
    await pumpPane(tester);
    await begin(tester);
    await tester.tap(find.text('Show solution'));
    await tester.pump();
    await tester.tap(find.byTooltip('3 stars'));
    await tester.pump();
    expect(w.trainer.up!.rating, 3);
    expect(find.byIcon(AppIcons.rated), findsNWidgets(3));
    expect(find.byIcon(AppIcons.unrated), findsNWidgets(2));
    await tester.tap(find.byTooltip('3 stars'));
    await tester.pump();
    expect(w.trainer.up!.rating, 0);
    expect(find.text('hidden from training'), findsNothing);
    await tester.tap(find.byTooltip('One star hides it from training'));
    await tester.pump();
    expect(w.trainer.up!.rating, 1);
    expect(find.text('hidden from training'), findsOneWidget);
  });

  testWidgets('ending a sitting shows what it came to; Retry plays the '
      'mistakes again and Done puts the recap away', (tester) async {
    await pumpPane(tester);
    await begin(tester);
    w.trainer.play('a7a6');
    await tester.pump();
    await tester.tap(find.text('End session'));
    await tester.pump();
    expect(find.text('Session complete'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Skipped'), findsNothing);
    expect(
      find.text('Accuracy 0% · 0.0s total · avg 0.0s per puzzle'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Retry mistakes (1)'), findsOne);
    expect(find.widgetWithText(OutlinedButton, 'Done'), findsOne);
    await tester.tap(find.text('Retry mistakes (1)'));
    await tester.pump();
    await tester.pump();
    expect(w.trainer.run!.queue, hasLength(1));
    expect(find.text('Puzzle 1 of 1'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Session complete'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);
    expect(find.textContaining('Accuracy'), findsNothing, reason: 'no tries');
    await tester.tap(find.text('Retry mistakes (1)'));
    await tester.pump();
    await tester.pump();
    w.trainer.end();
    await tester.pump();
    w.trainer.closeRecap();
    await tester.pump();
    expect(find.text('Session complete'), findsNothing);
  });

  testWidgets('a sitting with no puzzle up says it is paused and can be '
      'ended', (tester) async {
    await pumpPane(tester, available: 4);
    await begin(tester);
    w.trainer.putDown();
    await tester.pump();
    expect(find.text('Session paused; your results are kept.'), findsOne);
    expect(find.textContaining('ready to play'), findsNothing);
    await tester.tap(find.text('End session'));
    await tester.pump();
    expect(w.trainer.run, isNull);
    expect(find.text('Session complete'), findsOneWidget);
  });

  test('times read in seconds, whole seconds from ten, minutes from sixty', () {
    expect(formatSeconds(4.24), '4.2s');
    expect(formatSeconds(10), '10s');
    expect(formatSeconds(21.4), '21s');
    expect(formatSeconds(59.4), '59s');
    expect(formatSeconds(60), '1m 0s');
    expect(formatSeconds(252.4), '4m 12s');
  });
}
