/// [CandidateInjector] on its own: which sources offer a move, how the
/// offers are deduplicated and gated, and how they are scored.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/candidate_injector.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

const _base = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
  maxEvalLossCp: 50,
);

BookMove _book(String uci, int games, {int lastYear = 2024}) => BookMove(
  uci: uci,
  games: games,
  whiteWins: 0,
  draws: games,
  blackWins: 0,
  averageElo: 2600,
  maxElo: 2700,
  lastYear: lastYear,
  topGameId: 1,
  recentGameId: 2,
);

BuildRun _run({
  required TreeBuildConfig config,
  required BuildTreeNode root,
  required FakeStockfishPool pool,
  BookLookup? masterBook,
}) {
  final tree = BuildTree(root: root)..registerNode(root);
  return BuildRun(
    config: config,
    tree: tree,
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
}

BuildTreeNode _root() {
  resetNodeIds();
  return makeNode(fen: kStandardStartFen, san: '', ply: 0, isWhiteToMove: true)
    ..searchPriority = 1.0;
}

/// A MultiPV child already on [root], the way the expander leaves it.
void _existingChild(BuildRun run, BuildTreeNode root, String uci, int cpWhite) {
  final played = run.childMove(root, uci)!;
  final child = run.makeChild(
    parent: root,
    fen: played.fen,
    san: played.san,
    uci: uci,
    position: played.after,
  )!;
  child.engineEvalCp = child.isWhiteToMove ? cpWhite : -cpWhite;
}

void main() {
  test(
    'setup moves are scored together and gated by the eval window',
    () async {
      final root = _root();
      final afterD4 = playUciMove(kStandardStartFen, 'd2d4')!;
      final afterH4 = playUciMove(kStandardStartFen, 'h2h4')!;
      final pool = FakeStockfishPool()
        ..stmCpByFen[afterD4] =
            -30 // +30 for White: 10cp behind, kept
        ..stmCpByFen[afterH4] = 20; // -20 for White: 60cp behind, rejected
      final run = _run(
        config: _base.copyWith(setupMoves: 'h4, d4 e4'),
        root: root,
        pool: pool,
      );
      _existingChild(run, root, 'e2e4', 40);

      await CandidateInjector(run).inject(root, bestCpWhite: 40);

      expect(pool.injectionSearches.single, unorderedEquals(['h2h4', 'd2d4']));
      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'd4']),
      );
      final d4 = root.children.firstWhere((c) => c.moveSan == 'd4');
      expect(d4.engineEvalCp, -30, reason: 'stored side-to-move relative');
      expect(d4.moveProbability, 1.0);
    },
  );

  test(
    'the master book offers its top moves only at master practice',
    () async {
      final root = _root();
      final afterD4 = playUciMove(kStandardStartFen, 'd2d4')!;
      final pool = FakeStockfishPool()..stmCpByFen[afterD4] = -30;
      List<BookMove> book(String fen) => fen == kStandardStartFen
          ? [_book('e2e4', 900), _book('d2d4', 800), _book('c2c4', 200)]
          : const [];

      final run = _run(
        config: _base.copyWith(masterMinGames: 3),
        root: root,
        pool: pool,
        masterBook: book,
      );
      _existingChild(run, root, 'e2e4', 40);
      await CandidateInjector(run).inject(root, bestCpWhite: 40);

      // e4 is already a child, d4 is the second slot, c4 is outside the slots.
      expect(pool.injectionSearches.single, ['d2d4']);
      expect(run.stats.masterCandidatesInjected, 1);
      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'd4']),
      );
      // Both book children get the year the move was last played.
      expect(root.children.map((c) => c.lastPlayedYear), everyElement(2024));

      // Below the practice floor the book offers nothing.
      final thin = _root();
      final thinPool = FakeStockfishPool();
      final thinRun = _run(
        config: _base.copyWith(masterMinGames: 5000),
        root: thin,
        pool: thinPool,
        masterBook: book,
      );
      await CandidateInjector(thinRun).inject(thin, bestCpWhite: 40);
      expect(thinPool.injectionSearches, isEmpty);
      expect(thin.children, isEmpty);
    },
  );

  test(
    'a pin is offered ungated even when a setup move offers it too',
    () async {
      final root = _root();
      final afterH4 = playUciMove(kStandardStartFen, 'h2h4')!;
      final pool = FakeStockfishPool()
        ..stmCpByFen[afterH4] = 200; // -200 for White: far outside the window
      final plan = SkeletonPlan.fromLines(['1.h4'], playAsWhite: true);
      final run = _run(
        config: _base.copyWith(setupMoves: 'h4', skeletonPlan: plan),
        root: root,
        pool: pool,
      );
      _existingChild(run, root, 'e2e4', 40);

      await CandidateInjector(run).inject(root, bestCpWhite: 40);

      expect(pool.injectionSearches.single, ['h2h4']);
      expect(
        root.children.map((c) => c.moveSan),
        unorderedEquals(['e4', 'h4']),
      );
    },
  );

  test(
    'sources can be restricted, and no candidates means no search',
    () async {
      final root = _root();
      final pool = FakeStockfishPool()
        ..stmCpByFen[playUciMove(kStandardStartFen, 'h2h4')!] = 0;
      final run = _run(
        config: _base.copyWith(setupMoves: 'h4'),
        root: root,
        pool: pool,
      );

      await CandidateInjector(
        run,
      ).inject(root, bestCpWhite: 40, sources: const {InjectionSource.pin});

      expect(pool.injectionSearches, isEmpty);
      expect(pool.evalCalls, isEmpty);
      expect(root.children, isEmpty);
    },
  );

  test('a skeleton transfer is offered at a near-identical position', () async {
    // The skeleton answers 1.d4 with ...Nf6; at 1.c4 the same move transfers.
    final afterC4 = playUciMove(kStandardStartFen, 'c2c4')!;
    resetNodeIds();
    final node = makeNode(fen: afterC4, san: 'c4', ply: 1, isWhiteToMove: false)
      ..searchPriority = 1.0;
    final afterNf6 = playUciMove(afterC4, 'g8f6')!;
    final pool = FakeStockfishPool()..stmCpByFen[afterNf6] = 10;
    final plan = SkeletonPlan.fromLines(['1.d4 Nf6'], playAsWhite: false);
    final run = _run(
      config: _base.copyWith(playAsWhite: false, skeletonPlan: plan),
      root: node,
      pool: pool,
    );
    final injector = CandidateInjector(run);

    expect(injector.transferFor(node)?.uci, 'g8f6');
    await injector.inject(node, bestCpWhite: null);

    expect(pool.injectionSearches.single, ['g8f6']);
    expect(node.children.single.moveSan, 'Nf6');
  });
}
