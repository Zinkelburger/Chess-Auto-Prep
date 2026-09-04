library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/widgets/clickable_move_line.dart';
import 'package:chess_auto_prep/widgets/game_analysis_tab.dart';
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
