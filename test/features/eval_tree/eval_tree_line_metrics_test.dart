import 'package:chess_auto_prep/features/eval_tree/adapters/eval_tree_snapshot_adapter.dart';
import 'package:chess_auto_prep/features/eval_tree/services/eval_tree_line_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'eval_tree_test_helpers.dart';

void main() {
  group('EvalTreeLineMetricsCache', () {
    late EvalTreeLineMetricsCache cache;

    setUp(() {
      final tree = makeEvalTreeTestTree();
      final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
        tree,
        playAsWhite: true,
      );
      cache = EvalTreeLineMetricsCache.fromSnapshot(snapshot);
    });

    test('counts trap positions in subtree', () {
      final e4 = cache.snapshot.nodesById.values.firstWhere(
        (node) => node.moveSan == 'e4',
      );

      // e4 is an opponent-turn node with trapScore 0.32 in the test tree.
      expect(cache.metricsFor(e4.id).subtreeTrapCount, 1);
    });

    test('buildCandidateRows ranks repertoire moves first', () {
      final rootId = cache.snapshot.rootNodeId;
      final rows = buildCandidateRows(
        snapshot: cache.snapshot,
        metricsCache: cache,
        currentNodeId: rootId,
      );

      expect(rows.first.node.moveSan, 'e4');
      expect(rows.first.node.isRepertoireMove, isTrue);
    });

    test('buildCandidateRows assigns ranks', () {
      final rows = buildCandidateRows(
        snapshot: cache.snapshot,
        metricsCache: cache,
        currentNodeId: cache.snapshot.rootNodeId,
      );

      expect(rows.first.rank, 1);
      expect(rows.last.rank, rows.length);
    });
  });
}
