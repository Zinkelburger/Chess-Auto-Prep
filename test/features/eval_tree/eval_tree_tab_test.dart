import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/eval_tree/controllers/eval_tree_controller.dart';
import 'package:chess_auto_prep/features/eval_tree/widgets/eval_tree_tab.dart';

import 'eval_tree_test_helpers.dart';

void main() {
  Widget buildHarness({
    required Widget child,
    double width = 420,
    double height = 760,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );
  }

  testWidgets('tapping a visible node chip updates selection and position', (
    WidgetTester tester,
  ) async {
    final tree = makeEvalTreeTestTree();
    final e4 = tree.root.children.first;
    EvalTreeController? controller;
    EvalTreePositionSelection? selection;

    await tester.pumpWidget(
      buildHarness(
        child: EvalTreeTab(
          currentRepertoire: const {'filePath': '/tmp/test-repertoire.pgn'},
          isWhiteRepertoire: true,
          generatedTree: tree,
          onPositionSelected: (value) => selection = value,
          onControllerReady: (value) => controller = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('eval-tree-node-${e4.nodeId}')));
    await tester.pumpAndSettle();

    expect(controller, isNotNull);
    expect(controller!.selectedNodeId, e4.nodeId);
    expect(selection, isNotNull);
    expect(selection!.fen, e4.fen);
    expect(selection!.fullMovePathSan, ['e4']);
    expect(find.textContaining('1. e4'), findsOneWidget);
    expect(find.text('No nodes to display'), findsNothing);
  });

  testWidgets('keeps selection and controls across tab switches', (
    WidgetTester tester,
  ) async {
    final tree = makeEvalTreeTestTree();
    final e5 = tree.root.children
        .firstWhere((node) => node.moveSan == 'e4')
        .children
        .firstWhere((node) => node.moveSan == 'e5');
    EvalTreeController? controller;

    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Eval'),
                  Tab(text: 'Other'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                EvalTreeTab(
                  currentRepertoire: const {
                    'filePath': '/tmp/test-repertoire.pgn'
                  },
                  isWhiteRepertoire: true,
                  generatedTree: tree,
                  onControllerReady: (value) => controller = value,
                ),
                const Center(child: Text('Other tab')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller!.selectNode(e5.nodeId);
    controller!.setVisibleDepth(6);
    controller!.setAncestorSpine(false);
    controller!.setMetricDisplayMode(EvalTreeMetricDisplayMode.eval);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eval'));
    await tester.pumpAndSettle();

    expect(controller!.selectedNodeId, e5.nodeId);
    expect(controller!.visibleDepth, 6);
    expect(controller!.showAncestorSpine, isFalse);
    expect(controller!.metricDisplayMode, EvalTreeMetricDisplayMode.eval);
    expect(find.textContaining('1. e4 e5'), findsOneWidget);
    expect(find.text('No nodes to display'), findsNothing);
  });

  testWidgets('toolbar wraps cleanly on narrow panes', (
    WidgetTester tester,
  ) async {
    final tree = makeEvalTreeTestTree();

    await tester.pumpWidget(
      buildHarness(
        width: 320,
        child: EvalTreeTab(
          currentRepertoire: const {'filePath': '/tmp/test-repertoire.pgn'},
          isWhiteRepertoire: true,
          generatedTree: tree,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Ahead'), findsOneWidget);
    expect(find.text('Metric'), findsOneWidget);
    expect(find.text('CPL'), findsOneWidget);
    expect(find.text('No nodes to display'), findsNothing);
  });
}
