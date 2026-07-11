/// Integration tests for build-loop invariants that previously had no
/// coverage: the unified cancellation token, the synchronous re-entrancy
/// guard, buildComplete semantics, the coverage-sweep no-silent-holes
/// guarantee, resume-frontier collection, FenMap idempotency, and the
/// single opponent fan-out policy (addOpponentChildren).
///
/// Everything runs headless: BuildMode.maiaDbExplore with all eval
/// providers disabled makes the build loop traverse its real control flow
/// (floors, coverage, transpositions, explored-marking) without engines.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/node_expander.dart';
import 'package:chess_auto_prep/services/generation/opponent_prior.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';

import 'generation_test_helpers.dart';

/// Headless config: no Stockfish (maiaDbExplore), no eval DBs, no relative
/// eval (which would demand a root eval from a provider).
TreeBuildConfig _headlessConfig({
  double coverMinProb = 0.0,
  double minProbability = 0.0001,
  int maxPly = 4,
}) =>
    TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
      buildMode: BuildMode.maiaDbExplore,
      relativeEval: false,
      coverMinProb: coverMinProb,
      minProbability: minProbability,
      maxPly: maxPly,
    );

BuildRun _makeRun({
  required TreeBuildConfig config,
  required BuildTree tree,
  FenMap? fenMap,
  int nextNodeId = 1000,
}) {
  final stats = BuildStats();
  return BuildRun(
    config: config,
    tree: tree,
    fenMap: fenMap ?? FenMap(),
    pool: StockfishPool.instance,
    evalResolver: TreeEvalResolver()..stats = stats,
    stats: stats,
    runLog: RunDebugLog(),
    progress: TreeBuildProgressTracker(),
    onProgress: (_) {},
    cancel: BuildCancellation(),
    finishNow: () => false,
    waitIfPaused: () async {},
    nextNodeId: nextNodeId,
  );
}

BuildTree _singleNodeTree(BuildTreeNode root) {
  final tree = BuildTree(root: root, configSnapshot: const {});
  tree.registerNode(root);
  return tree;
}

void main() {
  group('BuildCancellation', () {
    test('starts not cancelled', () {
      final cancel = BuildCancellation();
      expect(cancel.isCancelled, isFalse);
      expect(cancel.stopRequested, isFalse);
    });

    test('requestStop cancels', () {
      final cancel = BuildCancellation()..requestStop();
      expect(cancel.isCancelled, isTrue);
      expect(cancel.stopRequested, isTrue);
    });

    test('external callback cancels without stopRequested', () {
      var flag = false;
      final cancel = BuildCancellation(isCancelledExternally: () => flag);
      expect(cancel.isCancelled, isFalse);
      flag = true;
      expect(cancel.isCancelled, isTrue);
      expect(cancel.stopRequested, isFalse);
    });
  });

  group('FenMap idempotency', () {
    test('populate twice adds no duplicate transpositions', () {
      final t = StandardTree();
      // Make two leaves share a FEN so one becomes a transposition leaf.
      final map = FenMap();
      map.populate(t.root);
      final before = map.getTranspositions(t.e4e5nf3.fen).length;
      map.populate(t.root);
      map.populate(t.root);
      expect(map.getTranspositions(t.e4e5nf3.fen).length, before);
    });

    test('addTransposition dedups by node identity', () {
      final t = StandardTree();
      final map = FenMap();
      map.putCanonical(t.e4e5.fen, t.e4e5);
      map.addTransposition(t.e4e5.fen, t.e4c5);
      map.addTransposition(t.e4e5.fen, t.e4c5);
      expect(map.getTranspositions(t.e4e5.fen).length, 1);
    });

    test('canonical node never lands in its own equivalence list', () {
      final t = StandardTree();
      final map = FenMap();
      // First populate registers leaves as canonical; a second populate
      // must not re-add a childless canonical as its own transposition.
      map.populate(t.root);
      map.populate(t.root);
      for (final leaf in [t.e4e5nf3, t.e4c5nf3, t.d4d5c4, t.d4nf6c4]) {
        for (final trans in map.getTranspositions(leaf.fen)) {
          expect(identical(trans, map.getCanonical(leaf.fen)), isFalse);
        }
      }
    });
  });

  group('evalWindowPrune', () {
    final config = TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
      minEvalCp: -50,
      maxEvalCp: 200,
    );

    test('no eval → no prune', () {
      final node = makeNode(
          fen: kFenAfterE4, san: 'e4', ply: 1, isWhiteToMove: false);
      expect(evalWindowPrune(node, config), isFalse);
      expect(node.pruneReason, PruneReason.none);
    });

    test('inside window → no prune', () {
      final node = makeNode(
          fen: kFenAfterE4,
          san: 'e4',
          ply: 1,
          isWhiteToMove: false,
          evalCp: -30); // STM (black) -30 → +30 for white
      expect(evalWindowPrune(node, config), isFalse);
    });

    test('above window → evalTooHigh with recorded eval', () {
      final node = makeNode(
          fen: kFenAfterE4,
          san: 'e4',
          ply: 1,
          isWhiteToMove: false,
          evalCp: -300); // +300 for white > maxEvalCp 200
      expect(evalWindowPrune(node, config), isTrue);
      expect(node.pruneReason, PruneReason.evalTooHigh);
      expect(node.pruneEvalCp, 300);
    });

    test('below window → evalTooLow', () {
      final node = makeNode(
          fen: kFenAfterE4,
          san: 'e4',
          ply: 1,
          isWhiteToMove: false,
          evalCp: 100); // -100 for white < minEvalCp -50
      expect(evalWindowPrune(node, config), isTrue);
      expect(node.pruneReason, PruneReason.evalTooLow);
    });
  });

  group('addOpponentChildren fan-out policy', () {
    // Parent: position after 1.e4 — black (opponent) to move.
    BuildTreeNode opponentNode() => makeNode(
          fen: kFenAfterE4,
          san: 'e4',
          uci: 'e2e4',
          ply: 1,
          isWhiteToMove: false,
          cumulativeProbability: 0.8,
        )..searchPriority = 0.8;

    SmoothedMove cand(String uci, double p, {int games = 100}) =>
        SmoothedMove(uci: uci, san: '', probability: p, games: games);

    test('raw probabilities, cumulative product, priority scaling', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(config: _headlessConfig(), tree: tree);

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.5), cand('c7c5', 0.3)],
        smoothing: false,
      );

      expect(node.children.length, 2);
      final e5 = node.children[0];
      expect(e5.moveProbability, 0.5);
      expect(e5.cumulativeProbability, closeTo(0.4, 1e-9));
      expect(e5.searchPriority, closeTo(0.4, 1e-9));
      // Raw, not renormalized: Σp = 0.8 stays 0.8.
      final mass = node.children
          .map((c) => c.moveProbability)
          .reduce((a, b) => a + b);
      expect(mass, closeTo(0.8, 1e-9));
    });

    test('coverage floor bypasses noise filter and caps', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(
        config: _headlessConfig(coverMinProb: 0.05),
        tree: tree,
      );

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.5, games: 1)], // below minGames
        smoothing: false,
        minGames: 10,
        maxChildren: 0,
      );

      expect(node.children.length, 1,
          reason: 'p=0.5 ≥ coverMinProb must survive the games filter');
    });

    test('noise filter drops sparse moves below the coverage floor', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(
        config: _headlessConfig(coverMinProb: 0.05),
        tree: tree,
      );

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.04, games: 1)],
        smoothing: false,
        minGames: 10,
      );

      expect(node.children, isEmpty);
    });

    test('smoothing disables the games filter', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(config: _headlessConfig(), tree: tree);

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.04, games: 1)],
        smoothing: true,
        minGames: 10,
      );

      expect(node.children.length, 1);
    });

    test('per-move probability floor applies independently of games', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(config: _headlessConfig(), tree: tree);

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.04)],
        smoothing: false,
        minMoveProb: 0.05,
      );

      expect(node.children, isEmpty);
    });

    test('maxChildren and massTarget stop the fan-out', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(config: _headlessConfig(), tree: tree);

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [
          cand('e7e5', 0.4),
          cand('c7c5', 0.3),
          cand('e7e6', 0.2),
        ],
        smoothing: false,
        maxChildren: 2,
      );
      expect(node.children.length, 2);

      final node2 = opponentNode();
      final tree2 = _singleNodeTree(node2);
      final run2 = _makeRun(config: _headlessConfig(), tree: tree2);
      addOpponentChildren(
        run: run2,
        node: node2,
        candidates: [
          cand('e7e5', 0.4),
          cand('c7c5', 0.3),
          cand('e7e6', 0.2),
        ],
        smoothing: false,
        massTarget: 0.6,
      );
      // 0.4 added (mass 0.4 < 0.6), 0.3 added (mass 0.7 ≥ 0.6), 0.2 stopped.
      expect(node2.children.length, 2);
    });

    test('cumulative floor skips unreachable moves', () {
      final node = opponentNode(); // cumP 0.8
      final tree = _singleNodeTree(node);
      final run = _makeRun(
        config: _headlessConfig(minProbability: 0.1),
        tree: tree,
      );

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.5), cand('c7c5', 0.05)],
        smoothing: false,
      );

      // 0.8*0.05 = 0.04 < 0.1 → skipped; 0.8*0.5 = 0.4 kept.
      expect(node.children.length, 1);
      expect(node.children.first.moveUci, 'e7e5');
    });

    test('attachStats copies W/B/D only when requested and games > 0', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(config: _headlessConfig(), tree: tree);

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [
          SmoothedMove(
            uci: 'e7e5',
            san: '',
            probability: 0.5,
            games: 10,
            whiteWins: 5,
            blackWins: 3,
            draws: 2,
          ),
        ],
        smoothing: false,
        attachStats: true,
      );

      expect(node.children.single.totalGames, 10);
    });

    test('onChild callback fires per added child', () {
      final node = opponentNode();
      final tree = _singleNodeTree(node);
      final run = _makeRun(config: _headlessConfig(), tree: tree);
      final seen = <String>[];

      addOpponentChildren(
        run: run,
        node: node,
        candidates: [cand('e7e5', 0.5), cand('c7c5', 0.3)],
        smoothing: false,
        onChild: (c) => seen.add(c.moveUci),
      );

      expect(seen, ['e7e5', 'c7c5']);
    });
  });

  group('TreeBuildService lifecycle', () {
    test('re-entrancy guard rejects an overlapping build before any await',
        () async {
      final service = TreeBuildService();
      final first = service.build(
        config: _headlessConfig(),
        isCancelled: () => false,
        onProgress: (_) {},
      );
      // Second call must fail even though the first has not completed a
      // single await yet — the guard is set synchronously.
      final second = service.build(
        config: _headlessConfig(),
        isCancelled: () => false,
        onProgress: (_) {},
      );
      await expectLater(second, throwsStateError);
      final tree = await first;
      expect(tree.totalNodes, greaterThanOrEqualTo(1));
      expect(service.isBuilding, isFalse);
    });

    test('completed headless build marks buildComplete', () async {
      final service = TreeBuildService();
      final tree = await service.build(
        config: _headlessConfig(),
        isCancelled: () => false,
        onProgress: (_) {},
      );
      expect(tree.buildComplete, isTrue);
      expect(tree.root.explored, isTrue);
    });

    test('externally cancelled build is NOT marked complete', () async {
      final service = TreeBuildService();
      final tree = await service.build(
        config: _headlessConfig(),
        isCancelled: () => true,
        onProgress: (_) {},
      );
      expect(tree.buildComplete, isFalse);
    });

    test('stopBuild during the run leaves the tree incomplete', () async {
      final service = TreeBuildService();
      var polls = 0;
      final tree = await service.build(
        config: _headlessConfig(),
        // Simulate an owner calling stopBuild concurrently: the loop polls
        // this callback, which triggers the stop on its first poll.
        isCancelled: () {
          if (polls++ == 0) service.stopBuild();
          return false;
        },
        onProgress: (_) {},
      );
      expect(tree.buildComplete, isFalse);
      expect(service.isBuilding, isFalse);
    });

    test('a second build works after the first finishes', () async {
      final service = TreeBuildService();
      await service.build(
        config: _headlessConfig(),
        isCancelled: () => false,
        onProgress: (_) {},
      );
      final tree2 = await service.build(
        config: _headlessConfig(),
        isCancelled: () => false,
        onProgress: (_) {},
      );
      expect(tree2.buildComplete, isTrue);
    });
  });

  group('resume frontier', () {
    test('collects unexplored leaves and inner nodes with min ply', () {
      final t = StandardTree();
      // Everything explored except one leaf and one inner node.
      void markExplored(BuildTreeNode n) {
        n.explored = true;
        for (final c in n.children) {
          markExplored(c);
        }
      }

      markExplored(t.root);
      t.e4e5nf3.explored = false; // leaf at ply 3
      t.d4.explored = false; // inner node at ply 1

      final (frontier, minPly) =
          TreeBuildService.prepareResumeFrontier(t.root);
      expect(frontier, containsAll([t.e4e5nf3, t.d4]));
      expect(minPly, 1);
    });

    test('legacy nodes without priority get reach probability on resume',
        () async {
      final t = StandardTree();
      void markExplored(BuildTreeNode n) {
        n.explored = true;
        for (final c in n.children) {
          markExplored(c);
        }
      }

      markExplored(t.root);
      // A legacy unexplored leaf: no searchPriority persisted.
      t.e4e5nf3.explored = false;
      t.e4e5nf3.searchPriority = -1.0;
      t.e4e5nf3.cumulativeProbability = 0.55;

      final tree = BuildTree(
        root: t.root,
        totalNodes: 11,
        configSnapshot: const {},
      );
      tree.computeMetadata();

      final service = TreeBuildService();
      await service.build(
        config: _headlessConfig(),
        isCancelled: () => false,
        onProgress: (_) {},
        existingTree: tree,
      );

      expect(t.e4e5nf3.searchPriority, closeTo(0.55, 1e-9));
    });
  });

  group('coverage sweep — no silent holes', () {
    test('removes dangling our-turn leaves below the coverage floor',
        () async {
      final t = StandardTree();
      void markExplored(BuildTreeNode n) {
        n.explored = true;
        for (final c in n.children) {
          markExplored(c);
        }
      }

      markExplored(t.root);
      // e4e5nf3 is an our-turn... no: nf3 nodes are black-to-move.  Use an
      // opponent reply whose answer is missing: e4e5 (white/our turn) with
      // children removed becomes a dangling our-turn leaf.
      t.e4e5.children.clear();
      t.e4e5.moveProbability = 0.02; // below coverMinProb 0.05

      final tree = BuildTree(
        root: t.root,
        totalNodes: 10, // 11 minus the removed nf3 leaf
        configSnapshot: const {},
      );
      tree.computeMetadata();
      final nodesBefore = tree.totalNodes;

      final service = TreeBuildService();
      final result = await service.build(
        config: _headlessConfig(coverMinProb: 0.05),
        isCancelled: () => false,
        onProgress: (_) {},
        existingTree: tree,
      );

      // The uncovered dangling leaf must be gone: its parent no longer
      // lists it and the node count dropped.
      expect(t.e4.children.contains(t.e4e5), isFalse,
          reason: 'uncovered our-turn hole must be removed');
      expect(result.totalNodes, lessThan(nodesBefore));
    });

    test('keeps answered positions intact', () async {
      final t = StandardTree();
      void markExplored(BuildTreeNode n) {
        n.explored = true;
        for (final c in n.children) {
          markExplored(c);
        }
      }

      markExplored(t.root);

      final tree = BuildTree(
        root: t.root,
        totalNodes: 11,
        configSnapshot: const {},
      );
      tree.computeMetadata();
      final nodesBefore = tree.totalNodes;

      final service = TreeBuildService();
      final result = await service.build(
        config: _headlessConfig(coverMinProb: 0.05),
        isCancelled: () => false,
        onProgress: (_) {},
        existingTree: tree,
      );

      // Every our-turn node already has an answer; nothing to sweep.
      expect(result.totalNodes, nodesBefore);
      expect(t.e4.children.contains(t.e4e5), isTrue);
    });
  });
}
