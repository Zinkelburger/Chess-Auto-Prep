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
    expect(find.text('Play tactics (3)'), findsOneWidget);
    expect(find.text('3 of 5'), findsOneWidget);
    expect(find.text('1 blunder, 1 mistake, 1 custom'), findsOneWidget);
    expect(find.text('1... f6?'), findsOneWidget);
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inaccuracies ?!'));
    await tester.pumpAndSettle();
    expect(find.text('Play tactics (4)'), findsOneWidget);
    expect(w.settings.value.puzzles.kinds.length, 4);
  });

  testWidgets('play brings the Puzzle tab up over a hidden answer; Space '
      'shows it', (tester) async {
    await toTactics(tester);
    await tester.tap(find.text('Play tactics (3)'));
    await tester.pumpAndSettle();
    expect(w.session.source, tacticsRef);
    expect(find.text('Black to play · 2 moves'), findsOneWidget);
    expect(find.text('Find the best move.'), findsOneWidget);
    expect(find.text('Puzzle 1 of 3'), findsOneWidget);
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
}
