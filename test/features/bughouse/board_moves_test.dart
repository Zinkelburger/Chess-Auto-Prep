// A board's move list in the Bughouse mode: how it numbers its moves, which
// one it marks, the step buttons under it and keeping the marked move in
// view.
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/features/bughouse/board_moves.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/ui/app_keys.dart';
import 'package:chess_auto_prep/ui/move_notation.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Role, Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BughouseLab lab;

  setUp(() => lab = BughouseLab());
  tearDown(() => lab.dispose());

  void play(List<String> moves) {
    for (final uci in moves) {
      lab.play(BoardNumber.one, uci);
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    bool figurines = false,
    double height = 400,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: MoveNotation(
            figurines: figurines,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                height: height,
                child: ListenableBuilder(
                  listenable: lab,
                  builder: (context, _) =>
                      BoardMoves(lab: lab, board: BoardNumber.one),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, AppKey key, String name) =>
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip(key.tip(name)),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed !=
      null;

  testWidgets('the step buttons are off where there is nowhere to go', (
    tester,
  ) async {
    play(['e2e4', 'e7e5']);
    await pump(tester);
    expect(enabled(tester, AppKey.firstMove, 'First move'), isTrue);
    expect(enabled(tester, AppKey.stepBack, 'Back'), isTrue);
    expect(enabled(tester, AppKey.stepForward, 'Forward'), isFalse);
    expect(enabled(tester, AppKey.lastMove, 'Last move'), isFalse);
    await tester.tap(find.byTooltip(AppKey.firstMove.tip('First move')));
    await tester.pumpAndSettle();
    expect(lab.line.upto(BoardNumber.one), 0);
    expect(enabled(tester, AppKey.firstMove, 'First move'), isFalse);
    expect(enabled(tester, AppKey.stepBack, 'Back'), isFalse);
    expect(enabled(tester, AppKey.stepForward, 'Forward'), isTrue);
    expect(enabled(tester, AppKey.lastMove, 'Last move'), isTrue);
  });

  testWidgets('Last move goes to the end of the line', (tester) async {
    play(['e2e4', 'e7e5', 'g1f3']);
    lab.goTo(BoardNumber.one, null);
    await pump(tester);
    await tester.tap(find.byTooltip(AppKey.lastMove.tip('Last move')));
    await tester.pumpAndSettle();
    expect(lab.line.upto(BoardNumber.one), 3);
  });

  testWidgets('a move after a hand edit shows its number again', (
    tester,
  ) async {
    play(['e2e4']);
    lab.adjustHand(BoardNumber.one, Side.white, Role.knight, 1);
    play(['e7e5']);
    await pump(tester);
    expect(find.text('+N'), findsOneWidget);
    expect(find.text('1... e5'), findsOneWidget);
  });

  testWidgets('the main line goes on numbered after a variation', (
    tester,
  ) async {
    play(['e2e4']);
    lab.goTo(BoardNumber.one, null);
    play(['d2d4']);
    lab.goTo(BoardNumber.one, lab.line.children(BoardNumber.one, null).first);
    play(['e7e5']);
    await pump(tester);
    final variation = tester.getRect(find.text('1. d4'));
    final e5 = tester.getRect(find.text('1... e5'));
    expect(e5.top, greaterThan(variation.bottom));
  });

  testWidgets('the move the board is at is the one marked', (tester) async {
    final semantics = tester.ensureSemantics();
    play(['e2e4', 'e7e5']);
    await pump(tester);
    expect(tester.getSemantics(find.text('e5')), isSemantics(isSelected: true));
    expect(
      tester.getSemantics(find.text('1. e4')),
      isSemantics(isSelected: false),
    );
    semantics.dispose();
  });

  testWidgets('figurines are drawn when chosen', (tester) async {
    play(['g1f3']);
    await pump(tester, figurines: true);
    expect(find.text('1. ♘f3'), findsOneWidget);
  });

  testWidgets('a move clicked far up a long list is scrolled into view', (
    tester,
  ) async {
    // Knights out and back: forty moves.
    play([
      for (var i = 0; i < 10; i++) ...['g1f3', 'g8f6', 'f3g1', 'f6g8'],
    ]);
    await pump(tester, height: 120);
    final list = tester.getRect(find.byType(SingleChildScrollView));
    // At the end of the line, the last move shows and the first does not.
    expect(list.contains(tester.getCenter(find.text('Ng8').last)), isTrue);
    expect(list.contains(tester.getCenter(find.text('1. Nf3'))), isFalse);
    lab.goTo(BoardNumber.one, lab.line.lineOf(BoardNumber.one).first);
    await tester.pumpAndSettle();
    expect(list.contains(tester.getCenter(find.text('1. Nf3'))), isTrue);
  });
}
