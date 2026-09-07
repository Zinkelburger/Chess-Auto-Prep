import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/widgets/generation/training_plan_card.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

BuildTree fixture() {
  var id = 0;
  final root = BuildTreeNode(
    fen: kStandardStartFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: ++id,
  )..historyAware = true;
  BuildTreeNode add(
    BuildTreeNode parent,
    String uci,
    String san, {
    bool selected = false,
  }) {
    final c =
        BuildTreeNode(
            fen: playUciMove(parent.fen, uci)!,
            moveSan: san,
            moveUci: uci,
            ply: parent.ply + 1,
            isWhiteToMove: !parent.isWhiteToMove,
            nodeId: ++id,
            parent: parent,
          )
          ..historyAware = true
          ..isRepertoireMove = selected
          ..engineEvalCp = 0
          ..expectimaxValue = .5
          ..hasExpectimax = true;
    parent.children.add(c);
    parent.explored = true;
    return c;
  }

  final e4 = add(root, 'e2e4', 'e4', selected: true);
  for (final (uci, san) in [('e7e5', 'e5'), ('c7c5', 'c5')]) {
    final reply = add(e4, uci, san)
      ..moveProbability = .5
      ..cumulativeProbability = .5;
    add(reply, 'g1f3', 'Nf3', selected: true).cumulativeProbability = .5;
  }
  return BuildTree(root: root, totalNodes: id)..buildComplete = true;
}

Future<void> ready(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.text('Preparing study options…').evaluate().isEmpty) return;
  }
  fail('Study planning did not finish');
}

void main() {
  testWidgets(
    'study preview creates a separate marked PGN and never trims the tree',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tree = fixture();
      final before = serializeTreeJson(tree);
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TrainingPlanCard(
                tree: tree,
                config: const TreeBuildConfig(
                  startFen: kStandardStartFen,
                  playAsWhite: true,
                  maxPly: 3,
                ),
                name: 'Repertoire',
                onCreateStudy: (name, pgn) async {
                  saved = pgn;
                },
              ),
            ),
          ),
        ),
      );
      await ready(tester);
      expect(find.textContaining('distinct decisions'), findsOneWidget);
      expect(
        find.textContaining('weighted prepared decisions'),
        findsOneWidget,
      );
      expect(find.textContaining('Remove '), findsNothing);
      await tester.tap(find.byKey(const ValueKey('study-less-repetition')));
      await ready(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('create-training-study')),
      );
      await tester.tap(find.byKey(const ValueKey('create-training-study')));
      await tester.pumpAndSettle();
      expect(saved, contains('[%tstart]'));
      expect(saved, contains('[%tend]'));
      expect(serializeTreeJson(tree), before);
      expect(tester.takeException(), isNull);
    },
  );
}
