/// Tests for the per-mode node expanders with scripted engine + Maia fakes —
/// the engine-adjacent layer that previously had no direct coverage.
///
/// Covers [StockfishExpander] our-move expansion (candidate filtering, STM
/// eval signs, PV-reply stashing, wide-opening MultiPV, Fast pruning zones,
/// alternative-subtree gating, coverage-only mode), the shared opponent
/// fan-out through the Maia source (mass target, coverage-floor bypass, PV
/// injection), and [MaiaDbExpander] DB-gated candidate selection.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
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
import 'package:chess_auto_prep/services/maia_factory.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

/// After 1.e4 e5 2.Nf3 Nc6 — an our-move (White) node at ply 4, past the
/// default wide-opening band (openingWidthPlies = 3).
const kItalianFen =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

const _base = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
);

BuildRun _makeRun({
  required TreeBuildConfig config,
  required BuildTree tree,
  required FakeStockfishPool pool,
}) {
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

BuildTree _treeWith(BuildTreeNode root) {
  final tree = BuildTree(root: root);
  tree.registerNode(root);
  return tree;
}

BuildTreeNode _child(BuildTreeNode node, String san) =>
    node.children.firstWhere((c) => c.moveSan == san);

void main() {
  tearDown(() => MaiaFactory.testOverride = null);

  group('StockfishExpander our-move expansion', () {
    test('root: wide MultiPV, eval-loss filter, STM signs, PV-reply stash, '
        'Maia frequencies, incumbent priorities', () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      )..searchPriority = 1.0;
      final pool = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['e2e4', 'e7e5']),
            discoveryLine(pvNumber: 2, cpWhite: 30, pv: ['d2d4']),
            // 60cp behind the best line: outside maxEvalLossCp (50).
            discoveryLine(pvNumber: 3, cpWhite: -20, pv: ['a2a3']),
          ],
        );
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kStandardStartFen: {'e2e4': 0.6, 'd2d4': 0.3},
      });

      final run = _makeRun(config: _base, tree: _treeWith(root), pool: pool);
      final queue = FrontierQueue(bestFirst: true);
      await NodeExpander.forRun(run).expandOurMove(root, queue);

      // Node eval from MultiPV line 0 (White to move: STM == White POV).
      expect(root.engineEvalCp, 40);

      // The root always gets the wide MultiPV floor.
      expect(pool.discoverMultiPvCalls.single, 10);

      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'd4']),
      );
      final e4 = _child(root, 'e4');
      final d4 = _child(root, 'd4');

      // Children are Black-to-move positions: STM eval is the negation.
      expect(e4.engineEvalCp, -40);
      expect(d4.engineEvalCp, -30);

      // Engine's expected reply is stashed only from MultiPV line 0.
      expect(e4.pvContinuationMove, 'e7e5');
      expect(d4.pvContinuationMove, isNull);

      expect(e4.maiaFrequency, closeTo(0.6, 1e-9));
      expect(d4.maiaFrequency, closeTo(0.3, 1e-9));

      // Incumbent (best eval for us) inherits the parent priority;
      // the alternative is discounted by ourAltDiscount.
      expect(e4.searchPriority, closeTo(1.0, 1e-9));
      expect(d4.searchPriority, closeTo(_base.ourAltDiscount, 1e-9));

      // Ply 0 is inside the wide-opening band: every child grows a subtree.
      expect(queue.length, 2);
    });

    test('past the opening band: alt within fastAltGapCp expands, '
        'a farther-behind alternative stays an evaluated leaf', () async {
      resetNodeIds();
      final node = makeNode(
        fen: kItalianFen,
        san: 'Nc6',
        ply: 4,
        isWhiteToMove: true,
      )..searchPriority = 0.05; // hot zone: full MultiPV
      final pool = FakeStockfishPool()
        ..discoveryByFen[kItalianFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['f1b5']),
            discoveryLine(pvNumber: 2, cpWhite: 35, pv: ['f1c4']),
            discoveryLine(pvNumber: 3, cpWhite: 5, pv: ['d2d4']),
          ],
        );
      MaiaFactory.testOverride = FakeMaiaEvaluator(const {});

      final run = _makeRun(config: _base, tree: _treeWith(node), pool: pool);
      final queue = FrontierQueue(bestFirst: true);
      await NodeExpander.forRun(run).expandOurMove(node, queue);

      expect(pool.discoverMultiPvCalls.single, _base.ourMultipv);
      expect(
        node.children.map((c) => c.moveSan),
        unorderedEquals(['Bb5', 'Bc4', 'd4']),
      );

      // Bb5 (incumbent) + Bc4 (5cp gap <= 30) grow subtrees; d4 (35cp gap)
      // stays an evaluated leaf that selection can still see.
      expect(queue.contains(_child(node, 'Bb5')), isTrue);
      expect(queue.contains(_child(node, 'Bc4')), isTrue);
      expect(queue.contains(_child(node, 'd4')), isFalse);
      expect(_child(node, 'd4').hasEngineEval, isTrue);
    });

    test(
      'cold node: MultiPV shrinks to 2 and the eval-loss window halves',
      () async {
        resetNodeIds();
        final node = makeNode(
          fen: kItalianFen,
          san: 'Nc6',
          ply: 4,
          isWhiteToMove: true,
        )..searchPriority = 0.001; // below fastColdPriority
        final pool = FakeStockfishPool()
          ..discoveryByFen[kItalianFen] = DiscoveryResult(
            lines: [
              discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['f1b5']),
              // 35cp behind: inside the full 50cp window, outside the halved 25.
              discoveryLine(pvNumber: 2, cpWhite: 5, pv: ['d2d4']),
            ],
          );
        MaiaFactory.testOverride = FakeMaiaEvaluator(const {});

        final run = _makeRun(config: _base, tree: _treeWith(node), pool: pool);
        await NodeExpander.forRun(
          run,
        ).expandOurMove(node, FrontierQueue(bestFirst: true));

        expect(pool.discoverMultiPvCalls.single, 2);
        expect(node.children.map((c) => c.moveSan), ['Bb5']);
      },
    );

    test('eval outside the window: node pruned, no children', () async {
      resetNodeIds();
      final node = makeNode(
        fen: kItalianFen,
        san: 'Nc6',
        ply: 4,
        isWhiteToMove: true,
      )..searchPriority = 1.0;
      final pool = FakeStockfishPool()
        ..discoveryByFen[kItalianFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 300, pv: ['f1b5']),
          ],
        );
      MaiaFactory.testOverride = FakeMaiaEvaluator(const {});

      final run = _makeRun(config: _base, tree: _treeWith(node), pool: pool);
      await NodeExpander.forRun(
        run,
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.pruneReason, PruneReason.evalTooHigh);
      expect(node.pruneEvalCp, 300);
      expect(node.children, isEmpty);
    });

    test(
      'coverageOnly: children created and evaluated, nothing enqueued',
      () async {
        resetNodeIds();
        final root = makeNode(
          fen: kStandardStartFen,
          san: '',
          ply: 0,
          isWhiteToMove: true,
        )..searchPriority = 1.0;
        final pool = FakeStockfishPool()
          ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
            lines: [
              discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['e2e4']),
              discoveryLine(pvNumber: 2, cpWhite: 30, pv: ['d2d4']),
            ],
          );
        MaiaFactory.testOverride = FakeMaiaEvaluator(const {});

        final run = _makeRun(config: _base, tree: _treeWith(root), pool: pool);
        final queue = FrontierQueue(bestFirst: true);
        await NodeExpander.forRun(
          run,
        ).expandOurMove(root, queue, coverageOnly: true);

        expect(root.children, hasLength(2));
        expect(root.children.every((c) => c.hasEngineEval), isTrue);
        expect(queue.isEmpty, isTrue);
      },
    );
  });

  group('opponent expansion via Maia (maiaOnly)', () {
    test('fan-out respects the mass target, missing PV reply is injected '
        'with its Maia probability', () async {
      resetNodeIds();
      final node =
          makeNode(
              fen: kFenAfterE4,
              san: 'e4',
              uci: 'e2e4',
              ply: 1,
              isWhiteToMove: false,
            )
            ..searchPriority = 1.0
            ..pvContinuationMove = 'g8f6';
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e5': 0.5, 'c7c5': 0.3, 'g8f6': 0.15, 'b8c6': 0.03},
      });

      final config = _base.copyWith(coverMinProb: 0.0);
      final run = _makeRun(
        config: config,
        tree: _treeWith(node),
        pool: FakeStockfishPool(),
      );
      final queue = FrontierQueue(bestFirst: true);
      await NodeExpander.forRun(run).expandOpponentMove(node, queue);

      // e5 (0.5) + c5 (0.3) reach the 0.8 mass target; Nf6 misses the cut
      // but returns as the engine-injected PV reply with Maia's probability.
      expect(
        node.children.map((c) => c.moveSan),
        unorderedEquals(['e5', 'c5', 'Nf6']),
      );
      final nf6 = _child(node, 'Nf6');
      expect(nf6.engineInjected, isTrue);
      expect(nf6.moveProbability, closeTo(0.15, 1e-9));
      expect(nf6.cumulativeProbability, closeTo(0.15, 1e-9));
      expect(_child(node, 'e5').moveProbability, closeTo(0.5, 1e-9));
      expect(_child(node, 'e5').engineInjected, isFalse);

      // All children (including the injected reply) enter the frontier.
      expect(queue.length, 3);
    });

    test('coverage floor bypasses the child cap: every reply at/above '
        'coverMinProb becomes a child even with oppMaxChildren = 1', () async {
      resetNodeIds();
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
      )..searchPriority = 1.0;
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e5': 0.5, 'c7c5': 0.3, 'g8f6': 0.15, 'b8c6': 0.03},
      });

      final config = _base.copyWith(coverMinProb: 0.05, oppMaxChildren: 1);
      final run = _makeRun(
        config: config,
        tree: _treeWith(node),
        pool: FakeStockfishPool(),
      );
      await NodeExpander.forRun(
        run,
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      // e5, c5, Nf6 all clear the 5% floor and bypass the cap and the mass
      // target; Nc6 (3%) is below the floor and filtered normally.
      expect(
        node.children.map((c) => c.moveSan),
        unorderedEquals(['e5', 'c5', 'Nf6']),
      );
    });
  });

  group('MaiaDbExpander', () {
    test('candidates need a DB eval and must pass the eval-loss filter; '
        'survivors get Maia frequency and STM evals', () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 30, // DB eval set by the build loop before expansion
      )..searchPriority = 1.0;
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kStandardStartFen: {
          'e2e4': 0.45,
          'd2d4': 0.35,
          'a2a3': 0.10, // no DB eval seeded: skipped
          'a2a4': 0.06, // seeded 70cp behind: eval-loss filtered
          'b1c3': 0.04, // below maiaMinProb (0.05)
        },
      });

      final fenAfterE4 = playUciMove(kStandardStartFen, 'e2e4')!;
      final fenAfterD4 = playUciMove(kStandardStartFen, 'd2d4')!;
      final fenAfterA4 = playUciMove(kStandardStartFen, 'a2a4')!;
      await EvalCache.instance.putEvalCpWhite(fenAfterE4, 35, 30);
      await EvalCache.instance.putEvalCpWhite(fenAfterD4, 25, 30);
      await EvalCache.instance.putEvalCpWhite(fenAfterA4, -40, 30);

      final config = _base.copyWith(buildMode: BuildMode.maiaDbExplore);
      final run = _makeRun(
        config: config,
        tree: _treeWith(root),
        pool: FakeStockfishPool(workers: 0),
      );
      final expander = NodeExpander.forRun(run);
      expect(expander, isA<MaiaDbExpander>());

      final queue = FrontierQueue(bestFirst: true);
      await expander.expandOurMove(root, queue);

      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'd4']),
      );
      final e4 = _child(root, 'e4');
      final d4 = _child(root, 'd4');

      // White-POV DB evals stored STM-relative on Black-to-move children.
      expect(e4.engineEvalCp, -35);
      expect(d4.engineEvalCp, -25);
      expect(e4.maiaFrequency, closeTo(0.45, 1e-9));

      expect(e4.searchPriority, closeTo(1.0, 1e-9));
      expect(d4.searchPriority, closeTo(config.ourAltDiscount, 1e-9));
      expect(queue.length, 2, reason: 'ply 0 is inside the wide-opening band');
    });
  });
}
