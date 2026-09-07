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

  testWidgets('one team at a time, with moves grouped by board', (
    tester,
  ) async {
    engine.resultsByTeam[Side.white] = result('(e2e4,pass)', '(g1f3,pass)');
    engine.resultsByTeam[Side.black] = result('(pass,d2d4)', '(pass,g1f3)');
    await pumpPanel(tester);
    expect(find.text('You + Partner'), findsNWidgets(2));
    expect(find.text('VARIATIONS'), findsNothing);
    expect(find.text('TO MOVE NOW'), findsNothing);
    expect(find.text('Board 1'), findsNWidgets(2));
    expect(find.text('Board 2'), findsNWidgets(2));
    expect(find.textContaining('e4', findRichText: true), findsOneWidget);
    expect(find.textContaining('d4', findRichText: true), findsNothing);
    for (var i = 0; i < 3; i++) {
      final slot = find.byKey(ValueKey('bughouse-line-slot-white-$i'));
      expect(tester.getSize(slot).height, 72);
      expect(find.byKey(ValueKey('bughouse-line-slot-black-$i')), findsNothing);
    }
    await tester.tap(find.text('Opponents'));
    await tester.pumpAndSettle();
    expect(find.textContaining('d4', findRichText: true), findsOneWidget);
    expect(find.textContaining('e4', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rules and engine controls open directly', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Position rules'));
    await tester.pumpAndSettle();
    expect(find.text('You play on Board 1'), findsOneWidget);
    expect(find.text('Allow sitting'), findsOneWidget);
    await tester.tap(find.text('Engine'));
    await tester.pumpAndSettle();
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Lines'), findsOneWidget);
    expect(find.text('Time per pass'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
