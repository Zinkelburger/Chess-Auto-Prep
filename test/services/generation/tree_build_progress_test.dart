import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

void main() {
  group('depthHistogram', () {
    test('counts totals and explored per ply', () {
      final t = StandardTree();
      t.root.explored = true;
      t.e4.explored = true;
      t.d4.explored = true;
      t.e4e5.explored = true;

      final (totals, explored) = TreeBuildProgressTracker.depthHistogram(
        t.root,
      );

      expect(totals, [1, 2, 4, 4]);
      expect(explored, [1, 2, 1, 0]);
    });

    test('depthLayerStats matches histogram layer', () {
      final t = StandardTree();
      t.e4e5.explored = true;

      final (total, unexplored) = TreeBuildProgressTracker.depthLayerStats(
        t.root,
        2,
      );
      expect(total, 4);
      expect(unexplored, 3);

      expect(TreeBuildProgressTracker.depthLayerStats(t.root, 9), (0, 0));
    });
  });

  group('best-first progress', () {
    BuildProgress emit(
      TreeBuildProgressTracker tracker,
      BuildTree tree,
      Stopwatch sw,
    ) {
      BuildProgress? out;
      tracker.emitProgress(
        tree,
        0,
        null,
        (p) => out = p,
        20,
        buildSw: sw,
        force: true,
      );
      return out!;
    }

    test('priority descent maps log-scale onto [0, 1]', () {
      final tracker = TreeBuildProgressTracker();
      tracker.reset(
        buildStartTotalNodes: 0,
        bestFirst: true,
        minProbability: 0.0001,
      );
      final tree = StandardTree().toTree();
      tree.maxPlyReached = 3;
      final sw = Stopwatch();

      tracker.onDequeue(0, priority: 1.0, frontierSize: 5);
      final atRoot = emit(tracker, tree, sw);
      expect(atRoot.bestFirst, isTrue);
      expect(atRoot.priorityProgress, 0.0);
      expect(atRoot.frontierSize, 5);
      expect(atRoot.etaDepthSeconds, isNull);
      expect(atRoot.depthTotals, [1, 2, 4, 4]);

      tracker.onDequeue(2, priority: 0.01, frontierSize: 12);
      final midway = emit(tracker, tree, sw);
      // ln(0.01)/ln(0.0001) = 0.5
      expect(midway.priorityProgress, closeTo(0.5, 1e-9));

      tracker.onDequeue(3, priority: 0.0001, frontierSize: 1);
      final atFloor = emit(tracker, tree, sw);
      expect(atFloor.priorityProgress, 1.0);
    });

    test('progress is monotone across descending pops', () {
      final tracker = TreeBuildProgressTracker();
      tracker.reset(
        buildStartTotalNodes: 0,
        bestFirst: true,
        minProbability: 0.001,
      );
      final tree = StandardTree().toTree();
      final sw = Stopwatch();

      var last = -1.0;
      for (final p in [1.0, 0.4, 0.4, 0.09, 0.02, 0.0011, 0.001]) {
        tracker.onDequeue(1, priority: p, frontierSize: 3);
        final progress = emit(tracker, tree, sw).priorityProgress!;
        expect(progress, greaterThanOrEqualTo(last));
        last = progress;
      }
      expect(last, 1.0);
    });

    test('no priority observed yet emits null progress', () {
      final tracker = TreeBuildProgressTracker();
      tracker.reset(
        buildStartTotalNodes: 0,
        bestFirst: true,
        minProbability: 0.001,
      );
      final tree = StandardTree().toTree();
      final p = emit(tracker, tree, Stopwatch());
      expect(p.priorityProgress, isNull);
      expect(p.etaRunSeconds, isNull);
    });
  });

  group('FIFO progress', () {
    test('emits current-layer stats and no priority progress', () {
      final tracker = TreeBuildProgressTracker();
      tracker.reset(buildStartTotalNodes: 0, minProbability: 0.0001);
      final t = StandardTree();
      t.e4e5.explored = true;
      final tree = t.toTree();
      final sw = Stopwatch();

      tracker.onDequeue(2);
      BuildProgress? out;
      tracker.emitProgress(
        tree,
        2,
        null,
        (p) => out = p,
        20,
        buildSw: sw,
        force: true,
      );

      expect(out!.bestFirst, isFalse);
      expect(out!.priorityProgress, isNull);
      expect(out!.currentDepth, 2);
      expect(out!.totalAtDepth, 4);
      expect(out!.unexploredAtDepth, 3);
    });
  });
}
