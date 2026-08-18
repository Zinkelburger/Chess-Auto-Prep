import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';
import 'package:chess_auto_prep/widgets/generation/skeleton_plan_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(GlobalKey<SkeletonPlanCardState> key) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SkeletonPlanCard(key: key, playAsWhite: false),
    ),
  ),
);

void main() {
  testWidgets('empty by default → empty plan, no-steer hint', (tester) async {
    final key = GlobalKey<SkeletonPlanCardState>();
    await tester.pumpWidget(_host(key));
    expect(key.currentState!.currentPlan().isEmpty, isTrue);
    expect(find.textContaining('runs normally'), findsOneWidget);
  });

  testWidgets('typed Benko lines produce pins and a confirmation', (
    tester,
  ) async {
    final key = GlobalKey<SkeletonPlanCardState>();
    await tester.pumpWidget(_host(key));
    await tester.enterText(
      find.byType(TextField),
      '1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6',
    );
    await tester.pump();
    final plan = key.currentState!.currentPlan();
    expect(plan.nodes.length, 5); // Nf6 c5 b5 a6 e6
    expect(plan.sourceLines.length, 1);
    expect(find.textContaining('pinned move'), findsOneWidget);
  });

  testWidgets('a veto chip toggles a structure feature', (tester) async {
    final key = GlobalKey<SkeletonPlanCardState>();
    await tester.pumpWidget(_host(key));
    await tester.tap(find.text('Avoid a pawn on d5'));
    await tester.pump();
    final plan = key.currentState!.currentPlan();
    expect(plan.features.whereType<PawnOnSquare>().length, 1);
  });

  testWidgets('loadPlan round-trips lines and vetoes', (tester) async {
    final key = GlobalKey<SkeletonPlanCardState>();
    await tester.pumpWidget(_host(key));
    final plan = SkeletonPlan.fromLines(
      const ['1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6'],
      playAsWhite: false,
      features: const [EarlyQueenTrade()],
    );
    key.currentState!.loadPlan(plan);
    await tester.pump();
    final back = key.currentState!.currentPlan();
    expect(back.nodes.length, plan.nodes.length);
    expect(back.features.whereType<EarlyQueenTrade>().length, 1);
  });
}
