/// [BuildRun]'s per-run memos: parsed positions, the master-book cache and
/// the incremental depth histogram.
library;

import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

const _config = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
);

BuildRun _run({
  TreeBuildConfig config = _config,
  BuildTree? tree,
  FakeStockfishPool? pool,
  BookLookup? masterBook,
}) {
  final stats = BuildStats();
  final root =
      tree?.root ??
      makeNode(fen: kStandardStartFen, san: '', ply: 0, isWhiteToMove: true);
  final built = tree ?? (BuildTree(root: root)..registerNode(root));
  return BuildRun(
    config: config,
    tree: built,
    fenMap: FenMap(),
    pool: pool ?? FakeStockfishPool(),
    evalResolver: TreeEvalResolver()..stats = stats,
    stats: stats,
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

BookMove _book(String uci, int games) => BookMove(
  uci: uci,
  games: games,
  whiteWins: 0,
  draws: games,
  blackWins: 0,
  averageElo: 2600,
  maxElo: 2700,
  lastYear: 2024,
  topGameId: 1,
  recentGameId: 2,
);

void main() {
  setUp(resetNodeIds);

  group('positions', () {
    test('childMove derives fen, SAN and position from the parent once', () {
      final run = _run();
      final root = run.tree.root;

      final e4 = run.childMove(root, 'e2e4')!;
      expect(e4.san, 'e4');
      expect(e4.fen, playUciMove(kStandardStartFen, 'e2e4'));
      expect(e4.after.turn, Side.black);

      // Illegal here: no piece on e5.
      expect(run.childMove(root, 'e5e4'), isNull);
      // Garbage never throws.
      expect(run.childMove(root, 'zz'), isNull);
    });

    test('a child made with its position never parses its FEN', () {
      final run = _run();
      final root = run.tree.root;
      final played = run.childMove(root, 'e2e4')!;
      final child = run.makeChild(
        parent: root,
        fen: played.fen,
        san: played.san,
        uci: 'e2e4',
        position: played.after,
      )!;
      expect(child.isWhiteToMove, isFalse);
      expect(identical(run.positionOf(child), played.after), isTrue);
    });

    test('positionOf is memoised per node', () {
      final run = _run();
      final root = run.tree.root;
      expect(identical(run.positionOf(root), run.positionOf(root)), isTrue);
    });

    test('an unparsable FEN falls back to the start position', () {
      final run = _run();
      final broken = makeNode(
        fen: 'not a fen',
        san: 'x',
        ply: 1,
        isWhiteToMove: false,
      );
      expect(run.positionOf(broken), Chess.initial);
    });
  });

  group('master book memo', () {
    test('a position is looked up once however often it is read', () {
      var lookups = 0;
      final run = _run(
        masterBook: (fen) {
          lookups++;
          return fen == kStandardStartFen
              ? [_book('e2e4', 30), _book('d2d4', 20)]
              : const [];
        },
      );

      expect(run.bookAt(kStandardStartFen), hasLength(2));
      expect(run.masterGamesAt(kStandardStartFen), 50);
      expect(run.masterPriorityFactor(kStandardStartFen), greaterThan(0));
      expect(run.isMasterPractice(kStandardStartFen), isTrue);
      // A different move order onto the same position shares the entry.
      expect(
        run.bookAt(kStandardStartFen.replaceAll(' 0 1', ' 3 7')),
        hasLength(2),
      );
      expect(lookups, 1);
      expect(run.stats.masterBookQueries, 1);
      expect(run.stats.masterBookHits, 1);

      // Misses are remembered too.
      expect(run.masterGamesAt(kFenAfterE4), 0);
      expect(run.masterGamesAt(kFenAfterE4), 0);
      expect(lookups, 2);
      expect(run.stats.masterBookQueries, 2);
      expect(run.stats.masterBookHits, 1);
    });

    test('a throwing book is logged, empty, and asked once', () {
      var lookups = 0;
      final run = _run(
        masterBook: (_) {
          lookups++;
          throw StateError('db gone');
        },
      );
      expect(run.bookAt(kStandardStartFen), isEmpty);
      expect(run.bookAt(kStandardStartFen), isEmpty);
      expect(lookups, 1);
    });
  });

  group('depth histogram', () {
    test('is seeded from the tree and kept exact by makeChild, markExplored '
        'and removeLeaf', () {
      final t = StandardTree();
      t.e4.explored = true;
      final tree = BuildTree(root: t.root)..computeMetadata();
      final run = _run(tree: tree);

      final (totals, explored) = TreeBuildProgressTracker.depthHistogram(
        t.root,
      );
      expect(run.depthTotals, totals);
      expect(run.depthExplored, explored);

      final played = run.childMove(t.e4e5nf3, 'b8c6')!;
      final child = run.makeChild(
        parent: t.e4e5nf3,
        fen: played.fen,
        san: played.san,
        uci: 'b8c6',
        position: played.after,
      )!;
      expect(run.depthTotals[4], 1);
      expect(run.depthExplored[4], 0);

      run.markExplored(child);
      run.markExplored(child); // idempotent
      expect(run.depthExplored[4], 1);

      run.removeLeaf(child);
      expect(run.depthTotals[4], 0);
      expect(run.depthExplored[4], 0);
      expect(t.e4e5nf3.children, isEmpty);
      expect(tree.nodeIndex.containsKey(child.nodeId), isFalse);

      final (afterTotals, afterExplored) =
          TreeBuildProgressTracker.depthHistogram(t.root);
      expect(run.depthTotals.take(4), afterTotals);
      expect(run.depthExplored.take(4), afterExplored);
    });
  });

  group('expansionLanes', () {
    test('one per worker under the thread budget, one without an engine', () {
      expect(
        _run(pool: FakeStockfishPool(workers: 4)).expansionLanes,
        4.clamp(1, _config.resolvedEngineThreads),
      );
      expect(
        _run(
          config: _config.copyWith(engineThreads: 2),
          pool: FakeStockfishPool(workers: 4),
        ).expansionLanes,
        2,
      );
      expect(
        _run(
          config: _config.copyWith(buildMode: BuildMode.maiaDbExplore),
          pool: FakeStockfishPool(workers: 4),
        ).expansionLanes,
        1,
      );
      expect(_run(pool: FakeStockfishPool(workers: 0)).expansionLanes, 1);
    });
  });

  group('positions', () {
    test('a node whose FEN will not parse yields no child', () {
      // Every expander derives children through `childMove`.  Playing the
      // move from a substituted initial board would attach a child for a
      // position the tree never reached, where the old FEN-taking helper
      // simply skipped the candidate.
      final bad = makeNode(
        fen: 'not a fen',
        san: '??',
        ply: 1,
        isWhiteToMove: true,
      );
      final run = _run(tree: BuildTree(root: bad));

      expect(run.positionOrNullOf(bad), isNull);
      expect(run.positionOf(bad), Chess.initial, reason: 'display fallback');
      expect(run.childMove(bad, 'e2e4'), isNull);
      // The failure is not memoised as the initial board either.
      expect(run.positionOrNullOf(bad), isNull);
    });

    test('a good FEN still derives its child', () {
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      );
      final run = _run(tree: BuildTree(root: root));

      final child = run.childMove(root, 'e2e4');
      expect(child, isNotNull);
      expect(child!.san, 'e4');
    });
  });
}
