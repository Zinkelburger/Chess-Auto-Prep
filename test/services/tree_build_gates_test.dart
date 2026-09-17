/// The frontier gates every build loop asks before expanding a node.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/frontier_queue.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/tree_build_gates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation/engine_fakes.dart';
import 'generation/generation_test_helpers.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

BuildRun _run({bool bestFirst = false, double minProbability = 0.05}) {
  final stats = BuildStats();
  final root = makeNode(
    fen: kStandardStartFen,
    san: '',
    ply: 0,
    isWhiteToMove: true,
  );
  return BuildRun(
    config: TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
      relativeEval: false,
      searchAlgorithm: bestFirst ? SearchAlgorithm.fast : SearchAlgorithm.pure,
      minProbability: minProbability,
    ),
    tree: BuildTree(root: root)..registerNode(root),
    fenMap: FenMap(),
    pool: FakeStockfishPool(),
    evalResolver: TreeEvalResolver()..stats = stats,
    stats: stats,
    runLog: RunDebugLog(),
    progress: TreeBuildProgressTracker(),
    onProgress: (_) {},
    cancel: BuildCancellation(),
    finishNow: () => false,
    waitIfPaused: () async {},
    nextNodeId: 1000,
  );
}

BuildTreeNode _leaf(BuildRun run, {required double reach, int id = 1}) =>
    makeNode(
      fen: _afterE4,
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      cumulativeProbability: reach,
      parent: run.tree.root,
      nodeId: id,
    );

void main() {
  group('belowSearchFloor', () {
    test('reach under the floor is below it', () {
      final run = _run(minProbability: 0.05);
      expect(run.belowSearchFloor(_leaf(run, reach: 0.04)), isTrue);
      expect(run.belowSearchFloor(_leaf(run, reach: 0.05)), isFalse);
    });

    test('best-first also gates on a discounted priority', () {
      final run = _run(bestFirst: true, minProbability: 0.05);
      final node = _leaf(run, reach: 0.5)..searchPriority = 0.01;
      expect(run.belowSearchFloor(node), isTrue);

      final breadthFirst = _run(bestFirst: false, minProbability: 0.05);
      expect(breadthFirst.belowSearchFloor(node), isFalse);
    });

    test('an unset priority (legacy tree) never counts against a node', () {
      final run = _run(bestFirst: true, minProbability: 0.05);
      final node = _leaf(run, reach: 0.5)..searchPriority = -1.0;
      expect(run.belowSearchFloor(node), isFalse);
    });
  });

  group('resolveTranspositionOrRegister', () {
    test('the first node at a position becomes canonical', () {
      final run = _run();
      final node = _leaf(run, reach: 0.5);
      final queue = FrontierQueue(bestFirst: false);

      expect(run.resolveTranspositionOrRegister(node, queue), isFalse);
      expect(run.fenMap.getCanonical(_afterE4), same(node));
      expect(node.explored, isFalse);
    });

    test('a second childless node folds its reach into the canonical', () {
      final run = _run();
      final canonical = _leaf(run, reach: 0.5, id: 1);
      final again = _leaf(run, reach: 0.25, id: 2);
      final queue = FrontierQueue(bestFirst: false);
      run.resolveTranspositionOrRegister(canonical, queue);

      expect(run.resolveTranspositionOrRegister(again, queue), isTrue);
      expect(again.explored, isTrue, reason: 'a transposition leaf is done');
      expect(run.fenMap.getCanonical(_afterE4), same(canonical));
      expect(run.fenMap.getTranspositions(_afterE4), [again]);
      expect(canonical.cumulativeProbability, closeTo(0.75, 1e-12));
    });

    test('a resumed node with children re-expands instead of folding', () {
      // The first registration keeps the canonical slot; the partial node
      // is neither folded in nor marked explored, so it expands again.
      final run = _run();
      final canonical = _leaf(run, reach: 0.5, id: 1);
      final partial = _leaf(run, reach: 0.25, id: 2);
      // makeNode attaches the child to its parent.
      makeNode(
        fen: kStandardStartFen,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        parent: partial,
        nodeId: 3,
      );
      final queue = FrontierQueue(bestFirst: false);
      run.resolveTranspositionOrRegister(canonical, queue);

      expect(run.resolveTranspositionOrRegister(partial, queue), isFalse);
      expect(partial.explored, isFalse);
      expect(run.fenMap.getCanonical(_afterE4), same(canonical));
      expect(run.fenMap.getTranspositions(_afterE4), isEmpty);
      expect(canonical.cumulativeProbability, 0.5);
    });
  });
}
