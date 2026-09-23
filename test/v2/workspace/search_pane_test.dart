import 'package:chess_auto_prep/v2/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/v2/workspace/search_pane.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

/// White king and pawn against a bare king: few moves, so a run is small.
const kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late SettingsStore settings;
  late FillGaps fill;

  setUp(() async {
    fixture = await openSession('[Event "x"]\n[Result "*"]\n\n*\n');
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    settings = SettingsStore();
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.white, root: const Fen(kingAndPawn)),
    );
    final root = positionOf(kingAndPawn);
    final afterE4 = afterUci(root, 'e2e4');
    fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(
          scores: {
            // e4 is a pawn better than anything else for White; after it,
            // Kf7 is played three games in ten and gives White two pawns.
            afterE4.fen: -100,
            afterUci(afterE4, 'e8f7').fen: 200,
          },
        ),
        policy: const ScriptedPolicy({'e8d8': 0.7, 'e8f7': 0.3}),
        release: () async {},
      ),
    );
  });

  tearDown(() {
    fill.dispose();
    settings.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 560,
          height: 480,
          child: SearchPane(
            fill: fill,
            session: fixture.session,
            settings: settings,
          ),
        ),
      ),
    ),
  );

  testWidgets('before a search: its three numbers and one button', (
    tester,
  ) async {
    await pump(tester);
    expect(find.widgetWithText(TextField, 'Opponent'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Depth'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
    expect(find.textContaining('for White'), findsOneWidget);
  });

  testWidgets('the values at the board, following it: our moves near the best, '
      'then their replies most played first with the trap marked', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Depth'), '2');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      // Let the run finish on real time.
      while (!fill.running) {
        await Future<void>.delayed(Duration.zero);
      }
      while (fill.running) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pumpAndSettle();
    expect(fill.depth, 2);
    expect(find.text('Your move'), findsOneWidget);
    expect(find.text('Expectimax'), findsOneWidget);
    // Only moves within half a pawn of the best are searched.
    expect(find.text('e4'), findsOneWidget);
    expect(find.text('e3'), findsNothing);
    await tester.tap(find.text('e4'));
    await tester.pumpAndSettle();
    expect(fixture.session.currentMove?.san, 'e4');
    expect(find.text('Their reply'), findsOneWidget);
    expect(find.text('Played'), findsOneWidget);
    expect(find.text('Kd8'), findsOneWidget);
    expect(find.text('Kf7?'), findsOneWidget, reason: 'a trap');
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    // Off the search: another root.
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.white, root: Fen.initial),
    );
    await tester.pumpAndSettle();
    expect(find.text('This position is not in the search.'), findsOneWidget);
    // Nothing to make lines of on the analysis board.
    expect(find.text('Make lines'), findsNothing);
  });
}
