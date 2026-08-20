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
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
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
    // Our turn means the opponent has already moved and the repertoire is
    // being asked what to play. "Nothing" is not an answer it may give, so
    // every path out of expandOurMove has to leave a move behind.
    group('always leaves us a move', () {
      // A dead-lost position for White, far below any sane floor.
      const lost = -900;

      BuildTreeNode ourNode() =>
          makeNode(fen: kItalianFen, san: 'Nf3', ply: 4, isWhiteToMove: true)
            ..searchPriority = 1.0;

      test('a hopeless position still gets the best move', () async {
        resetNodeIds();
        final node = ourNode();
        final pool = FakeStockfishPool()
          ..discoveryByFen[kItalianFen] = DiscoveryResult(
            lines: [
              discoveryLine(pvNumber: 1, cpWhite: lost, pv: ['f3g5']),
            ],
          );
        final config = _base.copyWith(minEvalCp: -50);

        await NodeExpander.forRun(
          _makeRun(config: config, tree: _treeWith(node), pool: pool),
        ).expandOurMove(node, FrontierQueue(bestFirst: true));

        expect(node.children.map((c) => c.moveSan), ['Ng5']);
      });

      test('a won position gets the move but no subtree to memorise', () async {
        resetNodeIds();
        final node = ourNode();
        final pool = FakeStockfishPool()
          ..discoveryByFen[kItalianFen] = DiscoveryResult(
            lines: [
              discoveryLine(pvNumber: 1, cpWhite: 900, pv: ['f3g5']),
            ],
          );
        final config = _base.copyWith(maxEvalCp: 200);
        final queue = FrontierQueue(bestFirst: true);

        await NodeExpander.forRun(
          _makeRun(config: config, tree: _treeWith(node), pool: pool),
        ).expandOurMove(node, queue);

        expect(node.children.map((c) => c.moveSan), ['Ng5']);
        expect(node.pruneReason, PruneReason.evalTooHigh);
        // Nothing queued: past the ceiling it is technique, not theory.
        expect(queue.isEmpty, isTrue);
      });
    });

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

    test('eval outside the window: node pruned, best move kept', () async {
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
      // The prune stops the *subtree*, not the answer: this is our turn, so
      // the engine's move is still recorded. It used to leave nothing here,
      // which read as a repertoire with no reply to a move already played.
      expect(node.children.map((c) => c.moveSan), ['Bb5']);
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

  group('opponent expansion via the master-games book', () {
    BookMove book(String uci, int games, {int ww = 0, int bw = 0}) => BookMove(
      uci: uci,
      games: games,
      whiteWins: ww,
      draws: games - ww - bw,
      blackWins: bw,
      averageElo: 2600,
      maxElo: 2700,
      lastYear: 2024,
      topGameId: 1,
      recentGameId: 2,
    );

    BuildTreeNode oppNode() => makeNode(
      fen: kFenAfterE4,
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
    )..searchPriority = 1.0;

    test('book frequencies drive the fan-out, blended with Maia, and carry '
        'game stats onto the children', () async {
      resetNodeIds();
      final node = oppNode();
      // Masters: 1...c5 700, 1...e5 250, 1...e6 50 (N = 1000 ≥ 100·λ, so
      // Maia is not even consulted: pure frequencies).
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e5': 0.9, 'g8f6': 0.1},
      });
      final run = BuildRun(
        config: _base.copyWith(coverMinProb: 0.0, maiaPriorGames: 10),
        tree: _treeWith(node),
        fenMap: FenMap(),
        pool: FakeStockfishPool(),
        evalResolver: TreeEvalResolver()..stats = BuildStats(),
        stats: BuildStats(),
        runLog: RunDebugLog(),
        progress: TreeBuildProgressTracker(),
        onProgress: (_) {},
        cancel: BuildCancellation(),
        finishNow: () => false,
        waitIfPaused: () async {},
        nextNodeId: 1000,
        masterBook: (fen) => fen == kFenAfterE4
            ? [
                book('c7c5', 700, ww: 300, bw: 250),
                book('e7e5', 250, ww: 100, bw: 80),
                book('e7e6', 50),
              ]
            : const [],
      );
      final queue = FrontierQueue(bestFirst: true);
      await NodeExpander.forRun(run).expandOpponentMove(node, queue);

      // c5 (0.70) + e5 (0.25) reach the 0.8 mass target.
      expect(
        node.children.map((c) => c.moveSan),
        unorderedEquals(['c5', 'e5']),
      );
      final c5 = _child(node, 'c5');
      expect(c5.moveProbability, closeTo(0.7, 1e-9));
      expect(c5.totalGames, 700);
      expect(c5.whiteWins, 300);
      expect(c5.lastPlayedYear, 2024);
      expect(node.totalGames, 1000);
      expect(queue.length, 2);
    });

    test('a thin book position falls back to Maia', () async {
      resetNodeIds();
      final node = oppNode();
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e5': 0.6, 'c7c5': 0.4},
      });
      final run = BuildRun(
        // priorGames 0 switches smoothing off, so the 2-game book sample
        // would have to stand alone — too thin, Maia takes over.
        config: _base.copyWith(coverMinProb: 0.0, maiaPriorGames: 0),
        tree: _treeWith(node),
        fenMap: FenMap(),
        pool: FakeStockfishPool(),
        evalResolver: TreeEvalResolver()..stats = BuildStats(),
        stats: BuildStats(),
        runLog: RunDebugLog(),
        progress: TreeBuildProgressTracker(),
        onProgress: (_) {},
        cancel: BuildCancellation(),
        finishNow: () => false,
        waitIfPaused: () async {},
        nextNodeId: 1000,
        masterBook: (_) => [book('d7d5', 2)],
      );
      await NodeExpander.forRun(
        run,
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      expect(
        node.children.map((c) => c.moveSan),
        unorderedEquals(['e5', 'c5']),
      );
      expect(node.totalGames, 0);
    });
  });

  group('master practice as the guide', () {
    BookMove book(String uci, int games, {int year = 2024}) => BookMove(
      uci: uci,
      games: games,
      whiteWins: 0,
      draws: games,
      blackWins: 0,
      averageElo: 2600,
      maxElo: 2700,
      lastYear: year,
      topGameId: 1,
      recentGameId: 2,
    );

    BuildRun runWith({
      required TreeBuildConfig config,
      required BuildTreeNode node,
      required FakeStockfishPool pool,
      BookLookup? masterBook,
    }) => BuildRun(
      config: config,
      tree: _treeWith(node),
      fenMap: FenMap(),
      pool: pool,
      evalResolver: TreeEvalResolver()..stats = BuildStats(),
      stats: BuildStats(),
      runLog: RunDebugLog(),
      progress: TreeBuildProgressTracker(),
      onProgress: (_) {},
      cancel: BuildCancellation(),
      finishNow: () => false,
      waitIfPaused: () async {},
      nextNodeId: 1000,
      masterBook: masterBook,
    );

    test('off-book positions fan out narrowly when a book is in use, '
        'and as before when there is no book at all', () async {
      // Four equally likely Maia replies; no mass target, no coverage floor,
      // so the only limit is the child cap.
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e5': 0.25, 'c7c5': 0.25, 'e7e6': 0.25, 'c7c6': 0.25},
      });
      final config = _base.copyWith(
        coverMinProb: 0.0,
        oppMassTarget: 1.0,
        maiaMinProb: 0.0,
        oppMaxChildren: 4,
      );
      BuildTreeNode oppNode() => makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
      )..searchPriority = 1.0;

      resetNodeIds();
      final withBook = oppNode();
      await NodeExpander.forRun(
        runWith(
          config: config,
          node: withBook,
          pool: FakeStockfishPool(),
          masterBook: (_) => const [], // book present, position unknown
        ),
      ).expandOpponentMove(withBook, FrontierQueue(bestFirst: true));
      expect(withBook.children.length, config.offBookOppMaxChildren);
      expect(withBook.children.length, 2);

      resetNodeIds();
      final noBook = oppNode();
      await NodeExpander.forRun(
        runWith(config: config, node: noBook, pool: FakeStockfishPool()),
      ).expandOpponentMove(noBook, FrontierQueue(bestFirst: true));
      expect(noBook.children.length, 4);

      // Narrowing switched off: the regular cap applies even off-book.
      resetNodeIds();
      final wide = oppNode();
      await NodeExpander.forRun(
        runWith(
          config: config.copyWith(offBookOppMaxChildren: 0),
          node: wide,
          pool: FakeStockfishPool(),
          masterBook: (_) => const [],
        ),
      ).expandOpponentMove(wide, FrontierQueue(bestFirst: true));
      expect(wide.children.length, 4);
    });

    test('the ply cap extends past maxPly only while the position is '
        'master practice', () {
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
      );
      final config = _base.copyWith(
        maxPly: 20,
        masterDepthBonusPlies: 10,
        masterMinGames: 3,
      );
      final practice = runWith(
        config: config,
        node: node,
        pool: FakeStockfishPool(),
        masterBook: (fen) => fen == kFenAfterE4
            ? [book('c7c5', 2), book('e7e5', 1)] // 3 games: practice
            : const [],
      );
      expect(practice.isMasterPractice(kFenAfterE4), isTrue);
      expect(practice.isMasterPractice(kStandardStartFen), isFalse);
      // Below maxPly the cap is maxPly regardless.
      expect(practice.plyCapAt(kFenAfterE4, 19), 20);
      // At/after maxPly a book position earns the bonus, an off-book one
      // does not.
      expect(practice.plyCapAt(kFenAfterE4, 20), 30);
      expect(practice.plyCapAt(kFenAfterE4, 29), 30);
      expect(practice.plyCapAt(kStandardStartFen, 20), 20);

      final thin = runWith(
        config: config,
        node: node,
        pool: FakeStockfishPool(),
        masterBook: (_) => [book('c7c5', 2)], // below masterMinGames
      );
      expect(thin.plyCapAt(kFenAfterE4, 20), 20);

      final noBook = runWith(
        config: config,
        node: node,
        pool: FakeStockfishPool(),
      );
      expect(noBook.plyCapAt(kFenAfterE4, 20), 20);

      final off = runWith(
        config: config.copyWith(masterDepthBonusPlies: 0),
        node: node,
        pool: FakeStockfishPool(),
        masterBook: (_) => [book('c7c5', 50)],
      );
      expect(off.plyCapAt(kFenAfterE4, 20), 20);
    });

    test('our-move expansion injects the book\'s most-played moves as '
        'eval-gated candidates and stamps recency', () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      )..searchPriority = 1.0;
      final afterD4 = playUciMove(kStandardStartFen, 'd2d4')!;
      final afterC4 = playUciMove(kStandardStartFen, 'c2c4')!;
      final afterB4 = playUciMove(kStandardStartFen, 'b2b4')!;
      final pool = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['e2e4']),
          ],
        )
        // Black to move after each: STM cp is the negation of White POV.
        ..stmCpByFen[afterD4] =
            -30 // +30 for White: inside the 50cp window
        ..stmCpByFen[afterC4] = -25
        ..stmCpByFen[afterB4] = 40; // -40 for White: 80cp behind, rejected
      MaiaFactory.testOverride = FakeMaiaEvaluator({kStandardStartFen: {}});

      final run = runWith(
        config: _base.copyWith(masterMinGames: 3),
        node: root,
        pool: pool,
        masterBook: (fen) => fen == kStandardStartFen
            ? [
                book('e2e4', 900, year: 2026), // already in MultiPV
                book('d2d4', 800, year: 2025),
                book('c2c4', 200, year: 2023),
                book('b2b4', 5), // third most-played: not offered
                book('g2g4', 2),
              ]
            : const [],
      );
      await NodeExpander.forRun(
        run,
      ).expandOurMove(root, FrontierQueue(bestFirst: true));

      // The book's two most-played moves are candidates: e4 was already
      // there from the engine, d4 is injected; c4 (third) and b4 are never
      // evaluated — the offer is bounded, not "everything masters play".
      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'd4']),
      );
      expect(pool.evalCalls, [afterD4]);
      expect(_child(root, 'd4').engineEvalCp, -30);
      expect(_child(root, 'e4').lastPlayedYear, 2026);
      expect(_child(root, 'd4').lastPlayedYear, 2025);
    });

    test('an injected master move outside the eval window is dropped, and '
        'a thin position injects nothing', () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      )..searchPriority = 1.0;
      final afterB4 = playUciMove(kStandardStartFen, 'b2b4')!;
      final pool = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['e2e4']),
          ],
        )
        ..stmCpByFen[afterB4] = 40;
      MaiaFactory.testOverride = FakeMaiaEvaluator({kStandardStartFen: {}});

      final run = runWith(
        config: _base.copyWith(masterMinGames: 3),
        node: root,
        pool: pool,
        masterBook: (_) => [book('b2b4', 50)],
      );
      await NodeExpander.forRun(
        run,
      ).expandOurMove(root, FrontierQueue(bestFirst: true));
      expect(root.children.map((c) => c.moveSan), ['e4']);
      expect(pool.evalCalls, [afterB4]);

      resetNodeIds();
      final root2 = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      )..searchPriority = 1.0;
      final pool2 = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 40, pv: ['e2e4']),
          ],
        );
      await NodeExpander.forRun(
        runWith(
          config: _base.copyWith(masterMinGames: 3),
          node: root2,
          pool: pool2,
          masterBook: (_) => [book('d2d4', 2)],
        ),
      ).expandOurMove(root2, FrontierQueue(bestFirst: true));
      expect(root2.children.map((c) => c.moveSan), ['e4']);
      expect(pool2.evalCalls, isEmpty);
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
