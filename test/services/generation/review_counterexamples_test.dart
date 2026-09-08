/// Counterexamples from the 5 September 2026 expectimax review
/// (`docs/maintenance/2026-09-05-expectimax-review.md`). Each asserts an
/// invariant the implementation is *supposed* to hold and does not: they are
/// the review's evidence, reproduced as code, and they fail on purpose.
///
/// Skipped rather than deleted, so the repair for each defect has a test
/// waiting for it. Drop the `skip` on the one you are fixing.
@Skip('Known failures: evidence for the expectimax review, not regressions.')
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/repertoire_verifier.dart';
import 'package:chess_auto_prep/utils/ease_utils.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/frontier_queue.dart';
import 'package:chess_auto_prep/services/generation/node_expander.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

const config = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
  minEvalCp: -9999,
  maxEvalCp: 9999,
);

BuildTreeNode root() => makeNode(
  fen: kStandardStartFen,
  san: '',
  ply: 0,
  isWhiteToMove: true,
  evalCp: 0,
);
BuildTreeNode child(
  BuildTreeNode p,
  String fen,
  String san,
  bool white,
  int cp,
) => makeNode(
  fen: fen,
  san: san,
  ply: p.ply + 1,
  isWhiteToMove: white,
  evalCp: cp,
  parent: p,
);

void main() {
  setUp(resetNodeIds);
  tearDown(() => MaiaFactory.testOverride = null);
  test(
    'PV injection must conserve opponent probability mass with book data',
    () async {
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: 0,
      )..pvContinuationMove = 'e7e5';
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'c7c5': 0.5, 'e7e5': 0.5},
      });
      final tree = BuildTree(root: node)..registerNode(node);
      final stats = BuildStats();
      final run = BuildRun(
        config: config,
        tree: tree,
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
        masterBook: (fen) => fen == kFenAfterE4
            ? [
                const BookMove(
                  uci: 'c7c5',
                  games: 3000,
                  whiteWins: 0,
                  draws: 3000,
                  blackWins: 0,
                  averageElo: 2600,
                  maxElo: 2700,
                  lastYear: 2024,
                  topGameId: 1,
                  recentGameId: 2,
                ),
              ]
            : [],
      );
      await NodeExpander.forRun(
        run,
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));
      expect(node.children, hasLength(2));
      final mass = node.children.fold(0.0, (v, c) => v + c.moveProbability);
      expect(mass, lessThanOrEqualTo(1.0));
    },
  );
  test('selected setup policy must equal the policy that was valued', () {
    final r = root();
    final e4 = child(r, kFenAfterE4, 'e4', false, -20);
    final d4 = child(r, kFenAfterD4, 'd4', false, 0);
    final cfg = config.copyWith(setupMoves: 'd4', setupToleranceCp: 30);
    final tree = BuildTree(root: r);
    final calc = ExpectimaxCalculator(config: cfg)..calculate(tree);
    RepertoireSelector(config: cfg, ecaCalc: calc).select(tree);
    expect(d4.isRepertoireMove, isTrue);
    expect(e4.isRepertoireMove, isFalse);
    expect(r.expectimaxValue, closeTo(d4.expectimaxValue, 1e-12));
  });

  test(
    'verification cannot certify an alternative using its shallow score',
    () async {
      final r = root();
      final e4 = child(r, kFenAfterE4, 'e4', false, -50)
        ..isRepertoireMove = true;
      final d4 = child(r, kFenAfterD4, 'd4', false, -30);
      final pool = FakeStockfishPool()
        ..stmCpByFen[e4.fen] = -48
        ..stmCpByFen[d4.fen] = -200;
      final tree = BuildTree(root: r);
      final fm = FenMap()..populate(r);
      final calc = ExpectimaxCalculator(config: config, fenMap: fm)
        ..calculate(tree);
      final report = await RepertoireVerifier(
        config: config,
        pool: pool,
      ).verify(tree, fenMap: fm, ecaCalc: calc);
      expect(report.completed, isTrue);
      expect(
        pool.evalCalls,
        contains(d4.fen),
        reason: 'Deep +200 beats chosen +48 by 152cp.',
      );
    },
  );

  test(
    'successful verification must refresh values even without a demotion',
    () async {
      final r = root();
      final e4 = child(r, kFenAfterE4, 'e4', false, -50)
        ..isRepertoireMove = true;
      final pool = FakeStockfishPool()..stmCpByFen[e4.fen] = -200;
      final tree = BuildTree(root: r);
      final fm = FenMap()..populate(r);
      final calc = ExpectimaxCalculator(config: config, fenMap: fm)
        ..calculate(tree);
      final report = await RepertoireVerifier(
        config: config,
        pool: pool,
      ).verify(tree, fenMap: fm, ecaCalc: calc);
      expect(report.completed, isTrue);
      expect(e4.engineEvalCp, -200);
      expect(r.expectimaxValue, closeTo(winProbability(200), 1e-12));
    },
  );

  test('a forced bad opponent reply must retain its prepared answer', () {
    final r = root();
    final e4 = child(r, kFenAfterE4, 'e4', false, 0);
    final e5 = child(e4, kFenAfterE4E5, 'e5', true, -150);
    final nf3 = child(e5, kFenAfterE4E5Nf3, 'Nf3', false, 150);
    final cfg = config.copyWith(minEvalCp: -100);
    final tree = BuildTree(root: r);
    final calc = ExpectimaxCalculator(config: cfg)..calculate(tree);
    RepertoireSelector(config: cfg, ecaCalc: calc).select(tree);
    expect(e4.isRepertoireMove, isTrue);
    expect(nf3.isRepertoireMove, isTrue);
  });

  test('multiple forward transposition dependencies need graph traversal', () {
    // Legal opening move orders. Eval payoffs are scripted to isolate the
    // graph backup from engine noise. Canonicals occur later in DFS order.
    final r = root();
    BuildTreeNode line(BuildTreeNode p, List<String> moves) {
      var n = p;
      for (final uci in moves) {
        final played = playUciMove(n.fen, uci)!;
        n = child(n, played, uci, !n.isWhiteToMove, 0);
      }
      return n;
    }

    final bAlias = line(r, ['g1f3', 'g8f6', 'g2g3', 'g7g6']);
    final b = line(r, ['g2g3', 'g8f6', 'g1f3', 'g7g6']);
    line(b, ['b2b3', 'b7b6']); // C alias
    final c = line(r, ['b2b3', 'g8f6', 'g2g3', 'g7g6', 'g1f3', 'b7b6']);
    line(c, ['f1g2']).engineEvalCp = -200;
    final tree = BuildTree(root: r);
    final fm = FenMap()..populate(r);
    final calc = ExpectimaxCalculator(config: config, fenMap: fm);
    calc.calculate(tree);
    expect(b.expectimaxValue, closeTo(winProbability(200), 1e-12));
    expect(bAlias.expectimaxValue, closeTo(b.expectimaxValue, 1e-12));
  });
}
