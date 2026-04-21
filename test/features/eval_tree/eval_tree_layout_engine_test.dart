import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/eval_tree/adapters/eval_tree_snapshot_adapter.dart';
import 'package:chess_auto_prep/features/eval_tree/controllers/eval_tree_controller.dart';
import 'package:chess_auto_prep/features/eval_tree/services/eval_tree_layout_engine.dart';

import 'eval_tree_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('layout engine produces deterministic positions for the same state', () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController()..loadSnapshot(snapshot);

    final firstFrame = EvalTreeLayoutEngine.buildFrame(snapshot, controller);
    final secondFrame = EvalTreeLayoutEngine.buildFrame(snapshot, controller);

    expect(firstFrame.nodesById.keys, secondFrame.nodesById.keys);
    for (final nodeId in firstFrame.nodesById.keys) {
      final firstNode = firstFrame.nodesById[nodeId]!;
      final secondNode = secondFrame.nodesById[nodeId]!;
      expect(firstNode.position, secondNode.position);
      expect(firstNode.size, secondNode.size);
    }
  });

  test(
      'node subtitle defaults to cpl for our moves and eval for opponent moves',
      () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );

    final d4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'd4');
    final e4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e4');
    final e5 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e5');

    expect(
      EvalTreeLayoutEngine.subtitleForNode(
        snapshot,
        d4,
        EvalTreeMetricDisplayMode.cpl,
      ),
      '6cpl',
    );
    expect(
      EvalTreeLayoutEngine.subtitleForNode(
        snapshot,
        e4,
        EvalTreeMetricDisplayMode.cpl,
      ),
      '18cpl',
    );
    expect(
      EvalTreeLayoutEngine.subtitleForNode(
        snapshot,
        e5,
        EvalTreeMetricDisplayMode.cpl,
      ),
      '+0.1',
    );
    expect(
      EvalTreeLayoutEngine.subtitleForNode(
        snapshot,
        e4,
        EvalTreeMetricDisplayMode.eval,
      ),
      '+0.3',
    );
  });

  test('graph secondary label follows the active metric mode', () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );

    final e4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e4');
    final e5 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e5');

    expect(
      EvalTreeLayoutEngine.secondaryLabelForNode(
        snapshot,
        e4,
        EvalTreeMetricDisplayMode.cpl,
      ),
      '18cpl',
    );
    expect(
      EvalTreeLayoutEngine.secondaryLabelForNode(
        snapshot,
        e5,
        EvalTreeMetricDisplayMode.cpl,
      ),
      '58% +0.1',
    );
    expect(
      EvalTreeLayoutEngine.secondaryLabelForNode(
        snapshot,
        e4,
        EvalTreeMetricDisplayMode.eval,
      ),
      '+0.3',
    );
  });

  test('layout engine grows nodes past the soft width cap when text needs it',
      () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController()..loadSnapshot(snapshot);
    final e4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e4');

    final frame = EvalTreeLayoutEngine.buildFrame(
      snapshot,
      controller,
      config: const EvalTreeLayoutConfig(minNodeWidth: 24, maxNodeWidth: 40),
    );

    expect(frame.nodesById[e4.id]!.size.width, greaterThan(40));
  });

  test(
      'layout engine keeps the ancestor path and only the selected node children',
      () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController()..loadSnapshot(snapshot);

    final root = snapshot.root;
    final d4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'd4');
    final e4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e4');
    final c5 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'c5');
    final e5 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e5');
    final bc4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'Bc4');
    final nf3 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'Nf3');

    controller.selectNode(e5.id, requestFocus: false);

    final frame = EvalTreeLayoutEngine.buildFrame(snapshot, controller);

    expect(frame.rootNodeId, root.id);
    expect(frame.nodesById.keys,
        containsAll([root.id, e4.id, e5.id, bc4.id, nf3.id]));
    expect(frame.tryNode(d4.id), isNull);
    expect(frame.tryNode(c5.id), isNull);
  });

  test('layout engine respects display caps and selected-root mode', () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController()..loadSnapshot(snapshot);

    final e5 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e5');
    controller.selectNode(e5.id, requestFocus: false);
    controller.setAncestorSpine(false);
    controller.setMaxDisplayNodes(3);

    final frame = EvalTreeLayoutEngine.buildFrame(snapshot, controller);

    expect(frame.rootNodeId, e5.id);
    expect(frame.nodesById.length, lessThanOrEqualTo(3));
    expect(frame.tryNode(e5.id), isNotNull);
  });

  test('layout engine keeps the selected node visible when the spine is capped',
      () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController()..loadSnapshot(snapshot);

    final root = snapshot.root;
    final e4 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e4');
    final e5 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'e5');
    final nf3 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'Nf3');

    controller.selectNode(nf3.id, requestFocus: false);
    controller.setMaxDisplayNodes(3);

    final frame = EvalTreeLayoutEngine.buildFrame(snapshot, controller);

    expect(frame.rootNodeId, e4.id);
    expect(frame.tryNode(root.id), isNull);
    expect(frame.tryNode(e4.id), isNotNull);
    expect(frame.tryNode(e5.id), isNotNull);
    expect(frame.tryNode(nf3.id), isNotNull);
  });

  test('layout engine marks capped frames when the visible budget is exhausted',
      () {
    final tree = makeEvalTreeTestTree();
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );
    final controller = EvalTreeController()..loadSnapshot(snapshot);

    controller.setMaxDisplayNodes(3);
    final frame = EvalTreeLayoutEngine.buildFrame(snapshot, controller);

    expect(frame.nodesById.length, 3);
    expect(frame.hitDisplayCap, isTrue);
  });
}
