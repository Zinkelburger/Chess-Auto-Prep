import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/eval_tree/adapters/eval_tree_snapshot_adapter.dart';

import 'eval_tree_test_helpers.dart';

void main() {
  test('build tree converts to immutable snapshot with derived viewer data',
      () {
    final tree = makeEvalTreeTestTree();
    tree.startMoves = 'd4 d5';

    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: true,
    );

    expect(snapshot.nodeCount, tree.totalNodes);
    expect(snapshot.root.childIds, hasLength(2));

    final firstChild = snapshot.node(snapshot.root.childIds.first);
    final secondChild = snapshot.node(snapshot.root.childIds.last);
    expect(firstChild.moveSan, 'e4');
    expect(secondChild.moveSan, 'd4');

    expect(firstChild.repertoireScore, closeTo(0.63, 0.001));
    expect(firstChild.evalForUsCp, 30);
    expect(firstChild.subtreePly, 2);
    expect(firstChild.trapScore, closeTo(0.32, 0.001));
    expect(snapshot.startMovesSan, ['d4', 'd5']);

    final nf3 =
        snapshot.nodesById.values.firstWhere((node) => node.moveSan == 'Nf3');
    expect(snapshot.movePathSan(nf3.id), ['e4', 'e5', 'Nf3']);
    expect(snapshot.fullMovePathSan(nf3.id), ['d4', 'd5', 'e4', 'e5', 'Nf3']);
  });
}
