import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_analysis_panel.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

void main() {
  late FakeBughouseEngine engine;
  late BughouseController controller;

  setUp(() {
    engine = FakeBughouseEngine(searchDelay: const Duration(milliseconds: 1));
    controller = BughouseController(engineOverride: engine);
  });

  tearDown(() => controller.dispose());

  BughouseSearchResult result(String first, String second) {
    BughouseInfo line(String action, int rank, int score) => BughouseInfo(
      depth: 5,
      scoreCp: score,
      nodes: 1200,
      nps: 400,
      timeMs: 2000,
      multipv: rank,
      pv: [BughouseJointMove.tryParse(action)!],
    );

    final principal = line(first, 1, -220);
    return BughouseSearchResult(
      best: principal.pv.first,
      ponder: null,
      infos: [principal, line(second, 2, -235)],
    );
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => BughouseAnalysisPanel(controller: controller),
            ),
          ),
        ),
      ),
    );
    for (
      var i = 0;
      i < 100 &&
          (controller.ours.lines.isEmpty || controller.theirs.lines.isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    // The production panel keeps thinking. Stop the zero-delay fake once its
    // two result blocks are visible so it cannot keep the test's microtask
    // queue alive after the assertions finish.
    controller.setAnalysisEnabled(false);
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('leads with candidates for each person who is on move', (
    tester,
  ) async {
    // At the initial position White is on move on both boards: that is us on
    // board 1 (seat A) and our partner's opponent on board 2 (seat D).
    engine.resultsByTeam[Side.white] = result('(e2e4,pass)', '(g1f3,pass)');
    engine.resultsByTeam[Side.black] = result('(pass,d2d4)', '(pass,g1f3)');

    await pumpPanel(tester);

    expect(find.text('TO MOVE NOW'), findsOneWidget);
    expect(find.text('BOARD 1 · PLAYER A'), findsOneWidget);
    expect(find.text('You · white'), findsOneWidget);
    expect(find.text('BOARD 2 · PLAYER D'), findsOneWidget);
    expect(find.text("Partner's opponent · white"), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bughouse-candidate-a-e4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bughouse-candidate-b-d4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bughouse-candidate-a-Nf3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bughouse-candidate-b-Nf3')),
      findsOneWidget,
    );
  });

  testWidgets('keeps joint variation preview instructions visible', (
    tester,
  ) async {
    engine.resultsByTeam[Side.white] = result('(e2e4,pass)', '(g1f3,pass)');
    engine.resultsByTeam[Side.black] = result('(pass,d2d4)', '(pass,g1f3)');

    await pumpPanel(tester);

    expect(find.text('VARIATIONS'), findsOneWidget);
    expect(find.text('YOUR TEAM'), findsOneWidget);
    expect(find.text('OTHER TEAM'), findsOneWidget);
    expect(find.textContaining('Hover a move to preview'), findsOneWidget);
  });
}
