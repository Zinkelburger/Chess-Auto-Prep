import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/widgets/game_analysis_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MoveEval evaluation(int ply, int cp) => MoveEval(
  ply: ply,
  san: 'Nf3',
  fenBefore: '',
  fenAfter: '',
  scoreCp: cp,
  winningChance: 0,
);

void main() {
  testWidgets('streamed offscreen scores preserve scale and scroll position', (
    tester,
  ) async {
    Widget chart(List<MoveEval> evals, {int currentPly = 40}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 350,
          child: GameAnalysisChart(
            evals: evals,
            totalPlies: 100,
            currentPly: currentPly,
          ),
        ),
      ),
    );
    await tester.pumpWidget(chart([evaluation(1, 20), evaluation(40, 10)]));
    await tester.pumpAndSettle();
    final before = tester.widget<LineChart>(find.byType(LineChart));
    final beforeSize = tester.getSize(find.byType(LineChart));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    scroll.position.jumpTo(200);
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      chart([evaluation(1, 20), evaluation(40, 10), evaluation(90, -790)]),
    );
    await tester.pumpAndSettle();
    final after = tester.widget<LineChart>(find.byType(LineChart));
    expect(after.data.minY, before.data.minY);
    expect(after.data.maxY, before.data.maxY);
    expect(after.data.maxX, 100);
    expect(after.data.lineBarsData, hasLength(1));
    expect(tester.getSize(find.byType(LineChart)), beforeSize);
    expect(scroll.position.pixels, 200);
    expect(after.duration, Duration.zero);

    // Navigation inside the viewport must not center on each step.
    await tester.pumpWidget(chart([evaluation(41, 20)], currentPly: 41));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, 200);
    expect(tester.takeException(), isNull);
  });
}
