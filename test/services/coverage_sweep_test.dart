/// [CoverageSweep] on a tree with no engine behind it: which dangling leaves
/// it removes, which it keeps, and what it records.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/coverage_sweep.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/node_expander.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation/engine_fakes.dart';
import 'generation/generation_test_helpers.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
const _afterE4E5 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';
const _afterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';

/// root (ours) → e4 (opponent to move) → e5 / c5 (ours to move, leaves).
({BuildRun run, BuildTreeNode e5, BuildTreeNode c5}) _tree({
  double coverMinProb = 0.05,
}) {
  final stats = BuildStats();
  final root = makeNode(
    fen: kStandardStartFen,
    san: '',
    ply: 0,
    isWhiteToMove: true,
  );
  final e4 = makeNode(
    fen: _afterE4,
    san: 'e4',
    ply: 1,
    isWhiteToMove: false,
    parent: root,
  );
  final e5 = makeNode(
    fen: _afterE4E5,
    san: 'e5',
    ply: 2,
    isWhiteToMove: true,
    moveProbability: 0.01,
    cumulativeProbability: 0.01,
    parent: e4,
  );
  final c5 = makeNode(
    fen: _afterE4C5,
    san: 'c5',
    ply: 2,
    isWhiteToMove: true,
    moveProbability: 0.01,
    cumulativeProbability: 0.01,
    parent: e4,
  );
  final tree = BuildTree(root: root, totalNodes: 4)..computeMetadata();
  final run = BuildRun(
    config: TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
      relativeEval: false,
      coverMinProb: coverMinProb,
    ),
    tree: tree,
    fenMap: FenMap(),
    pool: FakeStockfishPool(workers: 0),
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
  run.seedDepthHistogram();
  return (run: run, e5: e5, c5: c5);
}

void main() {
  test('a zero coverage floor sweeps nothing', () async {
    final t = _tree(coverMinProb: 0);
    final result = await CoverageSweep(
      t.run,
      NodeExpander.forRun(t.run),
    ).sweep();
    expect(result.closed, 0);
    expect(t.run.tree.totalNodes, 4);
  });

  test('our-turn leaves under the floor are removed and recorded', () async {
    final t = _tree();
    final result = await CoverageSweep(
      t.run,
      NodeExpander.forRun(t.run),
    ).sweep();

    expect(result.answered, 0);
    expect(result.removed, 2);
    expect(result.outOfTime, 0);
    expect(
      result.removedLines.map((l) => l.nodeId),
      unorderedEquals([t.e5.nodeId, t.c5.nodeId]),
    );
    final root = t.run.tree.root;
    expect(root.children.single.moveSan, 'e4', reason: 'opponent leaf stays');
    expect(root.children.single.children, isEmpty);
    expect(t.run.tree.totalNodes, 2);
  });

  test('an explicitly pruned leaf is not a hole', () async {
    final t = _tree();
    t.c5.pruneReason = PruneReason.evalTooHigh;
    final result = await CoverageSweep(
      t.run,
      NodeExpander.forRun(t.run),
    ).sweep();

    expect(result.removed, 1);
    expect(result.removedLines.single.nodeId, t.e5.nodeId);
    expect(t.run.tree.root.children.single.children, [t.c5]);
  });
}
