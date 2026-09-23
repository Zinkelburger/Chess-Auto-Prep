import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/v2/workspace/prep_pane.dart';
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
  late FillGaps fill;
  late List<int> went;

  setUp(() async {
    fixture = await openSession('[Event "x"]\n[Result "*"]\n\n*\n');
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    went = [];
    await fixture.session.newAnalysisBoard(
      side: Side.white,
      root: const Fen(kingAndPawn),
    );
    final afterE4 = afterUci(positionOf(kingAndPawn), 'e2e4');
    fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: fixture.store,
      tools: (_) async => FillReady(
        // Kf7 is played three games in ten and gives White two pawns.
        evaluator: ScriptedEvaluator(
          scores: {afterUci(afterE4, 'e8f7').fen: 200},
        ),
        policy: const ScriptedPolicy({'e8d8': 0.7, 'e8f7': 0.3}),
        release: () async {},
      ),
    );
  });

  tearDown(() {
    fill.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 480,
          height: 480,
          child: PrepPane(fill: fill, session: fixture.session, onGo: went.add),
        ),
      ),
    ),
  );

  testWidgets('before a search it says what one does', (tester) async {
    await pump(tester);
    expect(find.textContaining('Generate searches from the board'), findsOne);
  });

  testWidgets('after one, the traps then the lines, each a click from the '
      'board', (tester) async {
    await pump(tester);
    await tester.runAsync(
      () => fill.start(const FillRequest(elo: 2200, depthPlies: 2, onceIn: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Traps · 1'), findsOneWidget);
    expect(find.text('Lines · 1'), findsOneWidget);
    // The mistake is marked, and where it is set is said under it.
    expect(find.textContaining('Kf7?', findRichText: true), findsOneWidget);
    expect(find.textContaining('after 1.e4 · played 30%'), findsOneWidget);
    await tester.tap(find.textContaining('Kf7?', findRichText: true));
    expect(went, [0]);
    await tester.tap(find.textContaining('1.e4', findRichText: true).last);
    expect(went, [0, 1]);
  });
}
