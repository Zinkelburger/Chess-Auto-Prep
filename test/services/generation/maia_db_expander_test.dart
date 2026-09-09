/// [MaiaDbExpander] — our moves from Maia's policy, gated on database evals.
///
/// `node_expander_test.dart` covers the happy path at a White root. These
/// pin the edges: the eval-loss window at a Black-to-move node (the sign
/// flips there), the candidate cap, the last-resort fallback move, illegal
/// policy tokens, a Maia failure, and the window prune during a coverage
/// sweep.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/frontier_queue.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/node_expander.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/maia/maia_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

/// A Maia that fails on every call, the way a broken ORT session does.
class _ThrowingMaia implements MaiaEvaluator {
  @override
  Future<void> initialize() async {}

  @override
  Future<MaiaResult> evaluate(String fen, int elo) async {
    throw StateError('maia down');
  }

  @override
  void dispose() {}
}

const _base = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
  buildMode: BuildMode.maiaDbExplore,
);

BuildRun _run({required TreeBuildConfig config, required BuildTreeNode node}) {
  final tree = BuildTree(root: node);
  tree.registerNode(node);
  final stats = BuildStats();
  return BuildRun(
    config: config,
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
}

/// White-POV eval for the position after [uci] from [fen], seeded deep
/// enough to clear any depth floor the eval chain applies.
Future<String> _seed(String fen, String uci, int cpWhite) async {
  final child = playUciMove(fen, uci)!;
  await EvalCache.instance.putEvalCpWhite(child, cpWhite, 30);
  return child;
}

BuildTreeNode _child(BuildTreeNode node, String san) =>
    node.children.firstWhere((c) => c.moveSan == san);

void main() {
  tearDown(() => MaiaFactory.testOverride = null);

  test(
    'at a Black-to-move node the eval-loss window is measured for Black',
    () async {
      resetNodeIds();
      // Our repertoire is Black; the opponent has just played 1.e4.
      // engineEvalCp is side-to-move relative, so +20 means Black is +20 —
      // White-POV that is -20, the reference the window is measured from.
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: 20,
      )..searchPriority = 1.0;
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e5': 0.5, 'a7a6': 0.4},
      });
      // ...e5 improves on the reference for Black (White-POV -100);
      // ...a6 hands White +60, an 80cp loss against the 50cp window.
      final afterE5 = await _seed(kFenAfterE4, 'e7e5', -100);
      await _seed(kFenAfterE4, 'a7a6', 60);

      final run = _run(config: _base.copyWith(playAsWhite: false), node: node);
      await NodeExpander.forRun(
        run,
      ).expandOurMove(node, FrontierQueue(bestFirst: false));

      expect(node.children.map((c) => c.moveSan), ['e5']);
      final e5 = _child(node, 'e5');
      expect(e5.fen, afterE5);
      // White to move after ...e5: STM eval equals the White-POV number.
      expect(e5.engineEvalCp, -100);
      expect(e5.evalForUs(false), 100);
    },
  );

  test(
    'the candidate cap keeps the most likely moves, in policy order',
    () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 30,
      )..searchPriority = 1.0;
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kStandardStartFen: {'e2e4': 0.5, 'd2d4': 0.3, 'c2c4': 0.2},
      });
      await _seed(kStandardStartFen, 'e2e4', 35);
      await _seed(kStandardStartFen, 'd2d4', 30);
      await _seed(kStandardStartFen, 'c2c4', 28);

      final run = _run(config: _base.copyWith(ourMultipv: 2), node: root);
      await NodeExpander.forRun(
        run,
      ).expandOurMove(root, FrontierQueue(bestFirst: false));

      expect(root.children.map((c) => c.moveSan), ['e4', 'd4']);
      expect(_child(root, 'e4').maiaFrequency, closeTo(0.5, 1e-9));
      expect(_child(root, 'd4').maiaFrequency, closeTo(0.3, 1e-9));
    },
  );

  test('with every candidate filtered, the most likely legal move is still '
      'played — without an eval, and it is enqueued', () async {
    resetNodeIds();
    // A position no test seeds: 1.e4 e5, White to move.
    final node = makeNode(
      fen: kFenAfterE4E5,
      san: 'e5',
      uci: 'e7e5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 30,
    )..searchPriority = 1.0;
    MaiaFactory.testOverride = FakeMaiaEvaluator({
      kFenAfterE4E5: {'g1f3': 0.6, 'f1c4': 0.4},
    });

    final run = _run(config: _base, node: node);
    final queue = FrontierQueue(bestFirst: false);
    await NodeExpander.forRun(run).expandOurMove(node, queue);

    expect(node.children.map((c) => c.moveSan), ['Nf3']);
    final nf3 = node.children.single;
    expect(nf3.hasEngineEval, isFalse);
    expect(nf3.maiaFrequency, closeTo(0.6, 1e-9));
    expect(nf3.moveProbability, 1.0);
    expect(nf3.cumulativeProbability, node.cumulativeProbability);
    // An eval-less only child is still the incumbent.
    expect(nf3.searchPriority, closeTo(1.0, 1e-9));
    expect(queue.contains(nf3), isTrue);
  });

  test('a policy token that is not a legal move here is skipped', () async {
    resetNodeIds();
    final root = makeNode(
      fen: kStandardStartFen,
      san: '',
      ply: 0,
      isWhiteToMove: true,
      evalCp: 30,
    )..searchPriority = 1.0;
    MaiaFactory.testOverride = FakeMaiaEvaluator({
      kStandardStartFen: {'e2e5': 0.9, 'e2e4': 0.1},
    });
    await _seed(kStandardStartFen, 'e2e4', 35);

    final run = _run(config: _base, node: root);
    await NodeExpander.forRun(
      run,
    ).expandOurMove(root, FrontierQueue(bestFirst: false));

    expect(root.children.map((c) => c.moveSan), ['e4']);
  });

  test(
    'a Maia failure leaves the node untouched rather than throwing',
    () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 30,
      )..searchPriority = 1.0;
      MaiaFactory.testOverride = _ThrowingMaia();

      final run = _run(config: _base, node: root);
      final queue = FrontierQueue(bestFirst: false);
      await NodeExpander.forRun(run).expandOurMove(root, queue);

      expect(root.children, isEmpty);
      expect(queue.isEmpty, isTrue);
      expect(run.stats.maiaEvals, 0);
    },
  );

  test(
    'a coverage-sweep hole above the eval ceiling still gets its answer',
    () async {
      resetNodeIds();
      // The build loop prunes our-move nodes before this expander sees them
      // in maiaDbExplore mode, so the in-expander prune only fires on the
      // coverage sweep's coverage-only call. The answer must still be there.
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 900,
      )..searchPriority = 1.0;
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kStandardStartFen: {'e2e4': 0.5, 'd2d4': 0.3},
      });
      await _seed(kStandardStartFen, 'e2e4', 900);

      final run = _run(config: _base.copyWith(maxEvalCp: 200), node: root);
      final queue = FrontierQueue(bestFirst: false);
      await NodeExpander.forRun(
        run,
      ).expandOurMove(root, queue, coverageOnly: true);

      expect(root.pruneReason, PruneReason.evalTooHigh);
      expect(root.pruneEvalCp, 900);
      expect(root.children.map((c) => c.moveSan), ['e4']);
      expect(queue.isEmpty, isTrue);
    },
  );
}
