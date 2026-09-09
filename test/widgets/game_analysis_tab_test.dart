library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/widgets/clickable_move_line.dart';
import 'package:chess_auto_prep/widgets/game_analysis_tab.dart';
import 'package:chess_auto_prep/widgets/game_analysis_chart.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/board/board_square_painter.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const analyzed =
      '[Event "Test"]\n[Result "*"]\n\n'
      '1. e4 {[%eval 0.20]} e5 {[%eval 0.15]} '
      '2. Nf3 {[%eval 0.25]} Nc6 {[%eval 0.20]} '
      '3. Bb5 {[%eval 0.30]} a6 {[%eval 0.30]} '
      '4. Ng5 {[%eval -6.00] [%pv Ba4,Nf6,O-O]} '
      'Qxg5 {[%eval -6.10]} *';

  testWidgets('graph navigation replaces the move selected on the board', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final analysis = GameAnalysisController();
    addTearDown(analysis.dispose);
    expect(
      await tester.runAsync(() => analysis.tryLoadFromPgn(analyzed)),
      isTrue,
    );
    final controller = PgnViewerWidgetController();
    Position position = Chess.initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Row(
              children: [
                SizedBox(
                  width: 320,
                  child: ChessBoardWidget(
                    position: position,
                    recentMoveSquares: controller.recentMoveSquares,
                  ),
                ),
                Expanded(
                  child: PgnViewerWidget(
                    pgnText: analyzed,
                    controller: controller,
                    onPositionChanged: (next) =>
                        setState(() => position = next),
                  ),
                ),
                Expanded(
                  child: GameAnalysisTab(
                    analysisController: analysis,
                    pgnController: controller,
                    currentPly: controller.mainLineIndex,
                    variationDepth: controller.variationDepth,
                    gamePgnText: analyzed,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tab = find.byType(GameAnalysisTab);
    BoardSquarePainter surface() => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(ChessBoardWidget),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((paint) => paint.painter)
        .whereType<BoardSquarePainter>()
        .single;
    GameAnalysisChart chart() =>
        tester.widget<GameAnalysisChart>(find.byType(GameAnalysisChart));
    final card = find.descendant(of: tab, matching: find.text('Ng5'));
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(surface().recentMoveSquares, {'f3', 'g5'});
    expect(chart().currentPly, 7);

    await tester.tap(find.descendant(of: tab, matching: find.text('Nf6')));
    await tester.pumpAndSettle();
    expect(surface().recentMoveSquares, {'g8', 'f6'});
    expect(surface().selectedSquare, isNull);
    expect(surface().highlightedSquares, isEmpty);
    expect(
      chart().currentPly,
      isNull,
      reason: 'the graph has no point for the variation on the board',
    );

    controller.goBack();
    await tester.pumpAndSettle();
    expect(surface().recentMoveSquares, {'b5', 'a4'});
    expect(chart().currentPly, isNull);

    chart().onPlySelected!(7);
    await tester.pumpAndSettle();
    expect(surface().recentMoveSquares, {'f3', 'g5'});
    expect(chart().currentPly, 7);
    expect(
      tester
          .widget<ClickableMoveLineWidget>(
            find.descendant(
              of: tab,
              matching: find.byType(ClickableMoveLineWidget),
            ),
          )
          .activeMoveIndex,
      isNull,
    );
  });

  testWidgets('analysis card gives its engine line a readable click target', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final analysis = GameAnalysisController();
    addTearDown(analysis.dispose);
    final loaded = await tester.runAsync(
      () => analysis.tryLoadFromPgn(analyzed),
    );
    expect(loaded, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameAnalysisTab(
            analysisController: analysis,
            pgnController: PgnViewerWidgetController(),
            currentPly: 7,
            gamePgnText: analyzed,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Blunder'), findsWidgets);
    expect(find.textContaining('BETTER LINE'), findsNothing);
    expect(find.textContaining('CLICK A MOVE'), findsNothing);
    final line = tester.widget<ClickableMoveLineWidget>(
      find.byType(ClickableMoveLineWidget),
    );
    expect(line.singleLine, isFalse);
    expect(line.fontSize, greaterThanOrEqualTo(14));

    // Every SAN is its own generous target; tapping one must not fall through
    // to the containing mistake card.
    await tester.tap(find.text('Nf6'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
