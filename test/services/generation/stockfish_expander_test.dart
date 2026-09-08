/// [StockfishExpander] — the MultiPV our-move step, at its edges.
///
/// `node_expander_test.dart` covers a White root and the Fast pruning
/// zones. These pin what it does not: the sign convention at a
/// Black-to-move node, mate scores through the eval-loss window and the
/// eval ceiling, an engine that answers with nothing, and a Maia failure.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
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
import 'package:chess_auto_prep/utils/eval_constants.dart' show mateToCp;
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

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

const _white = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
);

BuildRun _run({
  required TreeBuildConfig config,
  required BuildTreeNode node,
  required FakeStockfishPool pool,
}) {
  final tree = BuildTree(root: node);
  tree.registerNode(node);
  final stats = BuildStats();
  return BuildRun(
    config: config,
    tree: tree,
    fenMap: FenMap(),
    pool: pool,
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

BuildTreeNode _whiteRoot() =>
    makeNode(fen: kStandardStartFen, san: '', ply: 0, isWhiteToMove: true)
      ..searchPriority = 1.0;

BuildTreeNode _child(BuildTreeNode node, String san) =>
    node.children.firstWhere((c) => c.moveSan == san);

void main() {
  tearDown(() => MaiaFactory.testOverride = null);

  test('Black to move: node and child evals flip, the window reads for '
      'Black, and the PV reply is stashed', () async {
    resetNodeIds();
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
    final node = makeNode(
      fen: kFenAfterE4,
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
    )..searchPriority = 1.0;
    // White-POV lines, best for Black first: the engine orders by STM.
    final pool = FakeStockfishPool()
      ..discoveryByFen[kFenAfterE4] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: -20, pv: ['e7e5', 'g1f3']),
          discoveryLine(pvNumber: 2, cpWhite: -10, pv: ['c7c5']),
          // 70cp worse for Black than the best line: outside the window.
          discoveryLine(pvNumber: 3, cpWhite: 50, pv: ['a7a6']),
        ],
      );

    final run = _run(
      config: _white.copyWith(playAsWhite: false),
      node: node,
      pool: pool,
    );
    await NodeExpander.forRun(
      run,
    ).expandOurMove(node, FrontierQueue(bestFirst: false));

    // Node eval is side-to-move relative: -20 for White is +20 for Black.
    expect(node.engineEvalCp, 20);
    expect(node.children.map((c) => c.moveSan), unorderedEquals(['e5', 'c5']));
    // Children are White-to-move positions: STM eval equals White-POV.
    expect(_child(node, 'e5').engineEvalCp, -20);
    expect(_child(node, 'c5').engineEvalCp, -10);
    expect(_child(node, 'e5').evalForUs(false), 20);
    expect(_child(node, 'e5').pvContinuationMove, 'g1f3');
    expect(_child(node, 'c5').pvContinuationMove, isNull);
    // The incumbent is the child best for *Black*.
    expect(_child(node, 'e5').searchPriority, closeTo(1.0, 1e-9));
    expect(
      _child(node, 'c5').searchPriority,
      closeTo(_white.ourAltDiscount, 1e-9),
    );
  });

  group('mate scores', () {
    test('a forced mate for us trips the ceiling and keeps the move', () async {
      resetNodeIds();
      MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
      final root = _whiteRoot();
      final pool = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            const DiscoveryLine(
              pvNumber: 1,
              depth: 14,
              scoreMate: 2,
              pv: ['e2e4'],
            ),
            discoveryLine(pvNumber: 2, cpWhite: 30, pv: ['d2d4']),
          ],
        );

      final queue = FrontierQueue(bestFirst: false);
      await NodeExpander.forRun(
        _run(config: _white.copyWith(maxEvalCp: 200), node: root, pool: pool),
      ).expandOurMove(root, queue);

      expect(root.engineEvalCp, mateToCp(2));
      expect(root.pruneReason, PruneReason.evalTooHigh);
      expect(root.pruneEvalCp, mateToCp(2));
      // Only the mating move: the ceiling stops the alternatives too.
      expect(root.children.map((c) => c.moveSan), ['e4']);
      expect(root.children.single.engineEvalCp, -mateToCp(2));
      expect(queue.isEmpty, isTrue);
    });

    test(
      'a line that walks into mate never rides along as an alternative',
      () async {
        resetNodeIds();
        MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
        final root = _whiteRoot();
        final pool = FakeStockfishPool()
          ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
            lines: [
              discoveryLine(pvNumber: 1, cpWhite: 30, pv: ['e2e4']),
              const DiscoveryLine(
                pvNumber: 2,
                depth: 14,
                scoreMate: -5,
                pv: ['d2d4'],
              ),
            ],
          );

        await NodeExpander.forRun(
          _run(config: _white, node: root, pool: pool),
        ).expandOurMove(root, FrontierQueue(bestFirst: false));

        expect(root.children.map((c) => c.moveSan), ['e4']);
      },
    );
  });

  test('an engine that returns no lines leaves the node unanswered and '
      'unevaluated, without throwing', () async {
    resetNodeIds();
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
    final root = _whiteRoot();
    final pool = FakeStockfishPool()
      ..discoveryByFen[kStandardStartFen] = const DiscoveryResult();

    final queue = FrontierQueue(bestFirst: false);
    await NodeExpander.forRun(
      _run(config: _white, node: root, pool: pool),
    ).expandOurMove(root, queue);

    expect(root.children, isEmpty);
    expect(root.hasEngineEval, isFalse);
    expect(root.pruneReason, PruneReason.none);
    expect(queue.isEmpty, isTrue);
  });

  test(
    'a Maia failure costs the naturalness annotation, not the moves',
    () async {
      resetNodeIds();
      MaiaFactory.testOverride = _ThrowingMaia();
      final root = _whiteRoot();
      final pool = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['e2e4']),
            discoveryLine(pvNumber: 2, cpWhite: 30, pv: ['d2d4']),
          ],
        );

      final run = _run(config: _white, node: root, pool: pool);
      await NodeExpander.forRun(
        run,
      ).expandOurMove(root, FrontierQueue(bestFirst: false));

      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'd4']),
      );
      // -1.0 is the "never set" sentinel.
      expect(root.children.every((c) => c.maiaFrequency < 0), isTrue);
      expect(run.stats.maiaEvals, 0);
    },
  );
}
