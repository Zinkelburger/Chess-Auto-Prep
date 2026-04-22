import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/eval_tree/adapters/eval_tree_snapshot_adapter.dart';
import 'package:chess_auto_prep/features/eval_tree/controllers/eval_tree_controller.dart';

import 'eval_tree_test_helpers.dart';

void main() {
  test('controller tracks selection, navigation, and layout controls', () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController();

    controller.loadSnapshot(snapshot);
    expect(controller.selectedNodeId, snapshot.rootNodeId);
    expect(controller.visiblePly, 1);
    expect(controller.showAncestorSpine, isTrue);
    expect(controller.metricDisplayMode, EvalTreeMetricDisplayMode.cpl);

    final e4 = snapshot.childrenOf(snapshot.rootNodeId).first;
    expect(controller.selectNode(e4.id), isTrue);
    expect(controller.selectedNodeId, e4.id);

    expect(controller.goPreferredChild(), isTrue);
    expect(controller.selectedNode?.moveSan, 'e5');

    expect(controller.goParent(), isTrue);
    expect(controller.selectedNodeId, e4.id);

    controller.setVisiblePly(6);
    controller.setAncestorSpine(false);
    controller.setMaxDisplayNodes(120);
    controller.setMetricDisplayMode(EvalTreeMetricDisplayMode.eval);

    expect(controller.visiblePly, 6);
    expect(controller.showAncestorSpine, isFalse);
    expect(controller.maxDisplayNodes, 120);
    expect(controller.metricDisplayMode, EvalTreeMetricDisplayMode.eval);
    expect(controller.focusRequestId, greaterThan(0));
  });
}
