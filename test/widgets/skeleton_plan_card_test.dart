import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';
import 'package:chess_auto_prep/widgets/generation/skeleton_plan_card.dart';
import 'package:chess_auto_prep/widgets/generation/skeleton_plan_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(SkeletonPlanController controller) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SkeletonPlanCard(controller: controller, playAsWhite: false),
    ),
  ),
);

/// The plan the card would hand the form, for the side it is hosted on.
SkeletonPlan _plan(SkeletonPlanController controller) =>
    controller.currentPlan(playAsWhite: false);

void main() {
  late SkeletonPlanController controller;

  setUp(() => controller = SkeletonPlanController());
  tearDown(() => controller.dispose());

  testWidgets('empty by default → empty plan, no-steer hint', (tester) async {
    await tester.pumpWidget(_host(controller));
    expect(_plan(controller).isEmpty, isTrue);
    expect(find.textContaining('runs normally'), findsOneWidget);
  });

  testWidgets('typed Benko lines produce pins and a confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(_host(controller));
    await tester.enterText(
      find.byType(TextField),
      '1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6',
    );
    await tester.pump();
    final plan = _plan(controller);
    expect(plan.nodes.length, 5); // Nf6 c5 b5 a6 e6
    expect(plan.sourceLines.length, 1);
    expect(find.textContaining('pinned move'), findsOneWidget);
  });

  testWidgets('a veto chip toggles a structure feature', (tester) async {
    await tester.pumpWidget(_host(controller));
    await tester.tap(find.text('Avoid a pawn on d5'));
    await tester.pump();
    expect(_plan(controller).features.whereType<PawnOnSquare>().length, 1);
  });

  testWidgets('loadPlan round-trips lines and vetoes', (tester) async {
    await tester.pumpWidget(_host(controller));
    final plan = SkeletonPlan.fromLines(
      const ['1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6'],
      playAsWhite: false,
      features: const [EarlyQueenTrade()],
    );
    controller.loadPlan(plan);
    await tester.pump();
    final back = _plan(controller);
    expect(back.nodes.length, plan.nodes.length);
    expect(back.features.whereType<EarlyQueenTrade>().length, 1);
  });

  testWidgets('the plan survives the card being unmounted', (tester) async {
    await tester.pumpWidget(_host(controller));
    await tester.enterText(find.byType(TextField), '1.d4 Nf6 2.c4 c5');
    await tester.pump();

    // What the collapsed expander does: the widget goes, the state stays.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(_plan(controller).nodes.length, 2);
  });
}
