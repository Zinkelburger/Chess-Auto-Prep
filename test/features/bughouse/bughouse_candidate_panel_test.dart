import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_book.dart';
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
    controller = BughouseController(
      engineOverride: engine,
      bookOverride: BughouseBook.canned(
        status: const BughouseBookStatus(
          path: 'fixture',
          games: 0,
          maxPly: 16,
          minGames: 3,
          years: [2025],
        ),
        lookup: (_, _) => BughouseBookPosition.empty,
      ),
    );
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

  testWidgets('both boards show the lines for their side to move', (
    tester,
  ) async {
    engine.resultsByTeam[Side.white] = result('(e2e4,pass)', '(g1f3,pass)');
    engine.resultsByTeam[Side.black] = result('(pass,d2d4)', '(pass,g1f3)');
    await pumpPanel(tester);
    expect(find.text('Opponents'), findsNothing);
    expect(find.text('Board 1'), findsOneWidget);
    expect(find.text('Board 2'), findsOneWidget);
    expect(find.text('White to move'), findsNWidgets(2));
    expect(find.textContaining('e4', findRichText: true), findsOneWidget);
    expect(find.textContaining('d4', findRichText: true), findsOneWidget);
    for (final board in BughouseBoard.values) {
      for (var i = 0; i < 3; i++) {
        final slot = find.byKey(
          ValueKey('bughouse-line-slot-${board.name}-$i'),
        );
        expect(tester.getSize(slot).height, 36);
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('board lines follow turn changes and play joint continuations', (
    tester,
  ) async {
    controller.playMove(
      BughouseBoard.a,
      const NormalMove(from: Square.e2, to: Square.e4),
    );
    // Black on 1 and White on 2 now belong to the same team.
    engine.resultsByTeam[Side.black] = result('(e7e5,d2d4)', '(b8c6,g1f3)');
    await pumpPanel(tester);
    expect(find.text('Black to move'), findsOneWidget);
    expect(find.text('White to move'), findsOneWidget);
    expect(find.textContaining('e5', findRichText: true), findsOneWidget);
    expect(find.textContaining('d4', findRichText: true), findsOneWidget);
    await tester.tap(find.textContaining('d4', findRichText: true));
    await tester.pump();
    expect(controller.state.boardA.board.pieceAt(Square.e5)?.role, Role.pawn);
    expect(controller.state.boardB.board.pieceAt(Square.d4)?.role, Role.pawn);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'comparison opens Engine immediately and shows progress and results',
    (tester) async {
      engine.resultsByTeam[Side.white] = result('(e2e4,pass)', '(g1f3,pass)');
      engine.resultsByTeam[Side.black] = result('(pass,d2d4)', '(pass,g1f3)');
      await pumpPanel(tester);
      engine.searchDelay = const Duration(milliseconds: 100);
      await tester.tap(find.text('Board'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare clock scenarios'));
      await tester.pump();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      expect(find.text('Clock scenarios'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bughouse-clock-progress')),
        findsOneWidget,
      );
      expect(find.text('Comparing… 0 of 3 ready'), findsOneWidget);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('bughouse-clock-scenarios')))
            .dy,
        lessThan(250),
      );
      for (var i = 0; i < 30 && controller.scenarios.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Ahead (may sit)'), findsOneWidget);
      expect(find.text('Comparing… 1 of 3 ready'), findsOneWidget);
      for (var i = 0; i < 60 && controller.isComparing; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(find.text('Comparison complete'), findsOneWidget);
      expect(find.text('Level or behind'), findsOneWidget);
      expect(find.text('Forced to move on 1'), findsOneWidget);
      expect(find.text('Board 1: e4'), findsNWidgets(3));
      expect(
        find.byKey(const ValueKey('bughouse-clock-progress')),
        findsNothing,
      );
      controller.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e2, to: Square.e4),
      );
      await tester.pump();
      expect(find.text('Clock scenarios'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rules and engine controls open directly', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Board'));
    await tester.pumpAndSettle();
    expect(find.text('You play on Board 1'), findsOneWidget);
    expect(find.text('Allow sitting'), findsOneWidget);
    await tester.tap(find.text('Engine settings'));
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Lines'), findsOneWidget);
    expect(find.text('Time per pass'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    controller.toggleBook();
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(find.text('FICS archive'), findsOneWidget);
    expect(find.text('Memory'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
