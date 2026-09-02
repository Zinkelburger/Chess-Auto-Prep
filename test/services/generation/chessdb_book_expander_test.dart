/// [ChessDbBookExpander] — the mainline-book mode.
///
/// The contract under test: one move per position on our side, master
/// practice on theirs, a single-mainline tail once practice runs out, and a
/// line that never simply stops because the database has not been there.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/eval/db_move_list.dart';
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
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

/// Scripted stand-in for the whole ChessDB chain.
class _FakeMoveSource implements ExternalMoveProvider {
  _FakeMoveSource(this.byFen);

  final Map<String, List<DbMove>> byFen;
  final List<String> calls = [];

  @override
  Future<DbMoveList> lookupMoves(String fen) async {
    calls.add(fen);
    final moves = byFen[fen];
    if (moves == null || moves.isEmpty) return DbMoveList.empty;
    return DbMoveList(
      moves: DbMoveList.sorted(moves),
      source: DbMoveSource.cdbDirect,
    );
  }
}

const _base = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
  buildMode: BuildMode.chessDbBook,
  selectionMode: SelectionMode.engineOnly,
);

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

BuildRun _run({
  required TreeBuildConfig config,
  required BuildTreeNode node,
  required FakeStockfishPool pool,
  _FakeMoveSource? source,
  BookLookup? masterBook,
  BuildStats? stats,
}) {
  final tree = BuildTree(root: node);
  tree.registerNode(node);
  final s = stats ?? BuildStats();
  return BuildRun(
    config: config,
    tree: tree,
    fenMap: FenMap(),
    pool: pool,
    evalResolver: TreeEvalResolver()
      ..stats = s
      ..bookMovesOverride = source,
    stats: s,
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

BuildTreeNode _ourRoot() =>
    makeNode(fen: kStandardStartFen, san: '', ply: 0, isWhiteToMove: true)
      ..searchPriority = 1.0;

BuildTreeNode _oppNodeAfterE4() => makeNode(
  fen: kFenAfterE4,
  san: 'e4',
  uci: 'e2e4',
  ply: 1,
  isWhiteToMove: false,
)..searchPriority = 1.0;

void main() {
  tearDown(() => MaiaFactory.testOverride = null);

  group('our move', () {
    test('plays the database best move and nothing else', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [
          DbMove(uci: 'd2d4', stmCp: 25, rank: 1),
          DbMove(uci: 'e2e4', stmCp: 32, rank: 0),
          DbMove(uci: 'c2c4', stmCp: 24, rank: 1),
        ],
      });
      final queue = FrontierQueue(bestFirst: true);

      await NodeExpander.forRun(
        _run(
          config: _base,
          node: node,
          pool: FakeStockfishPool(),
          source: source,
        ),
      ).expandOurMove(node, queue);

      expect(node.children.map((c) => c.moveSan), ['e4']);
      expect(queue.isEmpty, isFalse);
    });

    test(
      'the child carries the database score, flipped to its own turn',
      () async {
        resetNodeIds();
        final node = _ourRoot();
        final source = _FakeMoveSource({
          kStandardStartFen: const [DbMove(uci: 'e2e4', stmCp: 32)],
        });

        await NodeExpander.forRun(
          _run(
            config: _base,
            node: node,
            pool: FakeStockfishPool(),
            source: source,
          ),
        ).expandOurMove(node, FrontierQueue(bestFirst: true));

        // +32 for White at the root; the child is Black to move, and
        // engineEvalCp is side-to-move relative there.
        expect(node.engineEvalCp, 32);
        expect(node.children.single.engineEvalCp, -32);
        expect(node.children.single.evalForUs(true), 32);
      },
    );

    test('exact ties go to the move masters played more', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [
          DbMove(uci: 'e2e4', stmCp: 30, rank: 0),
          DbMove(uci: 'd2d4', stmCp: 30, rank: 0),
        ],
      });

      await NodeExpander.forRun(
        _run(
          config: _base,
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (_) => [_book('d2d4', 9000), _book('e2e4', 100)],
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.single.moveSan, 'd4');
    });

    test('a move the database scores worse never wins a tie-break', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [
          DbMove(uci: 'e2e4', stmCp: 30),
          DbMove(uci: 'd2d4', stmCp: 29),
        ],
      });

      await NodeExpander.forRun(
        _run(
          // Default window is 0: only exact ties are ties.
          config: _base,
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (_) => [_book('d2d4', 9000), _book('e2e4', 100)],
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.single.moveSan, 'e4');
    });

    test('a widened window lets master practice decide', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [
          DbMove(uci: 'e2e4', stmCp: 30),
          DbMove(uci: 'd2d4', stmCp: 29),
        ],
      });

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(bookTieBreakWindowCp: 5),
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (_) => [_book('d2d4', 9000), _book('e2e4', 100)],
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.single.moveSan, 'd4');
    });

    test(
      'a reply window prefers the move leaving fewer good replies',
      () async {
        resetNodeIds();
        final node = _ourRoot();
        const afterD4 =
            'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';
        // dartchess writes no en-passant square when no capture is possible.
        const afterE4 =
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
        final source = _FakeMoveSource({
          kStandardStartFen: const [
            DbMove(uci: 'e2e4', stmCp: 30),
            DbMove(uci: 'd2d4', stmCp: 29),
          ],
          // After 1.e4 Black has three level replies; after 1.d4 only one.
          afterE4: const [
            DbMove(uci: 'e7e5', stmCp: -30),
            DbMove(uci: 'c7c5', stmCp: -31),
            DbMove(uci: 'e7e6', stmCp: -35),
            DbMove(uci: 'a7a5', stmCp: -120),
          ],
          afterD4: const [
            DbMove(uci: 'd7d5', stmCp: -29),
            DbMove(uci: 'g8f6', stmCp: -70),
          ],
        });

        await NodeExpander.forRun(
          _run(
            config: _base.copyWith(bookTieBreakWindowCp: 5, replyWindowCp: 20),
            node: node,
            pool: FakeStockfishPool(),
            source: source,
            // Masters overwhelmingly prefer e4; the reply count outranks them.
            masterBook: (_) => [_book('e2e4', 9000), _book('d2d4', 100)],
          ),
        ).expandOurMove(node, FrontierQueue(bestFirst: true));

        expect(node.children.single.moveSan, 'd4');
        expect(source.calls, containsAll([afterE4, afterD4]));
      },
    );

    test(
      'a reply window falls back to master practice on equal counts',
      () async {
        resetNodeIds();
        final node = _ourRoot();
        const afterD4 =
            'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';
        // dartchess writes no en-passant square when no capture is possible.
        const afterE4 =
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
        final source = _FakeMoveSource({
          kStandardStartFen: const [
            DbMove(uci: 'e2e4', stmCp: 30),
            DbMove(uci: 'd2d4', stmCp: 30),
          ],
          afterE4: const [DbMove(uci: 'e7e5', stmCp: -30)],
          afterD4: const [DbMove(uci: 'd7d5', stmCp: -30)],
        });

        await NodeExpander.forRun(
          _run(
            config: _base.copyWith(replyWindowCp: 20),
            node: node,
            pool: FakeStockfishPool(),
            source: source,
            masterBook: (_) => [_book('d2d4', 9000), _book('e2e4', 100)],
          ),
        ).expandOurMove(node, FrontierQueue(bestFirst: true));

        expect(node.children.single.moveSan, 'd4');
      },
    );

    test(
      'a position ChessDB has never seen ends the line by default',
      () async {
        resetNodeIds();
        final node = _ourRoot();
        final stats = BuildStats();

        await NodeExpander.forRun(
          _run(
            config: _base,
            node: node,
            // An engine is available; the mode declines to use it.
            pool: FakeStockfishPool(),
            source: _FakeMoveSource(const {}),
            stats: stats,
          ),
        ).expandOurMove(node, FrontierQueue(bestFirst: true));

        expect(node.children, isEmpty);
        expect(stats.bookEngineFallbacks, 0);
        expect(stats.bookDeadEnds, 1);
      },
    );

    test('with the floor on, the engine answers instead', () async {
      resetNodeIds();
      final node = _ourRoot();
      final stats = BuildStats();
      final pool = FakeStockfishPool()
        ..discoveryByFen[kStandardStartFen] = DiscoveryResult(
          lines: [
            discoveryLine(pvNumber: 1, cpWhite: 18, pv: ['d2d4']),
          ],
        );

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(bookEngineFallback: true),
          node: node,
          pool: pool,
          source: _FakeMoveSource(const {}),
          stats: stats,
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.single.moveSan, 'd4');
      expect(stats.bookEngineFallbacks, 1);
      expect(stats.bookDbMoveHits, 0);
    });

    test('no database and no engine ends the line, and says so', () async {
      resetNodeIds();
      final node = _ourRoot();
      final stats = BuildStats();

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(bookEngineFallback: true),
          node: node,
          pool: FakeStockfishPool(workers: 0),
          source: _FakeMoveSource(const {}),
          stats: stats,
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.children, isEmpty);
      expect(stats.bookDeadEnds, 1);
    });

    test('a decided position keeps the move but grows no subtree', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [DbMove(uci: 'e2e4', stmCp: 900)],
      });
      final queue = FrontierQueue(bestFirst: true);

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(maxEvalCp: 200),
          node: node,
          pool: FakeStockfishPool(),
          source: source,
        ),
      ).expandOurMove(node, queue);

      expect(node.children.map((c) => c.moveSan), ['e4']);
      expect(node.pruneReason, PruneReason.evalTooHigh);
      expect(queue.isEmpty, isTrue);
    });
  });

  group('their move', () {
    test('master practice branches, on recorded frequencies alone', () async {
      resetNodeIds();
      // Maia is available and would add moves through smoothing; this mode
      // must not let it.
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kFenAfterE4: {'e7e6': 0.9},
      });
      final node = _oppNodeAfterE4();

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(coverMinProb: 0.0, oppMassTarget: 1.0),
          node: node,
          pool: FakeStockfishPool(),
          source: _FakeMoveSource(const {}),
          masterBook: (fen) => fen == kFenAfterE4
              ? [_book('c7c5', 600), _book('e7e5', 400)]
              : const [],
        ),
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.map((c) => c.moveSan), ['c5', 'e5']);
      expect(node.children.first.moveProbability, closeTo(0.6, 1e-9));
    });

    test(
      'off master practice the line continues as one database move',
      () async {
        resetNodeIds();
        final node = _oppNodeAfterE4();
        final source = _FakeMoveSource({
          kFenAfterE4: const [
            DbMove(uci: 'c7c5', stmCp: -20),
            DbMove(uci: 'e7e5', stmCp: -14),
          ],
        });

        await NodeExpander.forRun(
          _run(
            config: _base,
            node: node,
            pool: FakeStockfishPool(),
            source: source,
            masterBook: (_) => const [], // a book, but nothing here
          ),
        ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

        expect(node.children.map((c) => c.moveSan), ['e5']);
        // A forced continuation costs the line no probability mass.
        expect(node.children.single.moveProbability, 1.0);
        expect(
          node.children.single.cumulativeProbability,
          node.cumulativeProbability,
        );
      },
    );

    test(
      'a book sample too thin to be practice takes the tail, not Maia',
      () async {
        resetNodeIds();
        MaiaFactory.testOverride = FakeMaiaEvaluator({
          kFenAfterE4: {'e7e6': 0.9, 'c7c6': 0.1},
        });
        final node = _oppNodeAfterE4();
        final source = _FakeMoveSource({
          kFenAfterE4: const [DbMove(uci: 'c7c5', stmCp: -20)],
        });

        await NodeExpander.forRun(
          _run(
            // masterMinGames 3 — a single game is not practice.
            config: _base,
            node: node,
            pool: FakeStockfishPool(),
            source: source,
            masterBook: (_) => [_book('e7e6', 1)],
          ),
        ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

        expect(node.children.map((c) => c.moveSan), ['c5']);
      },
    );
  });

  group('master-book breadth', () {
    // The bug this pins: `maiaMinProb` (a Maia policy floor) was gating
    // master-game counts, so the Four Pawns Attack — 1159 recorded games,
    // 4.2% of the position — was dropped from a King's Indian book with no
    // chess judgement involved.
    test('a well-played reply survives the probability floor', () async {
      resetNodeIds();
      final node = _oppNodeAfterE4();

      await NodeExpander.forRun(
        _run(
          // Floor at 5%: c7c6 is 4% of the position and would be cut. Caps
          // lifted so the floor is the only thing under test.
          config: _base.copyWith(
            maiaMinProb: 0.05,
            coverMinProb: 0.0,
            oppMaxChildren: 0,
            oppMassTarget: 0.0,
          ),
          node: node,
          pool: FakeStockfishPool(),
          source: _FakeMoveSource(const {}),
          masterBook: (_) => [_book('c7c5', 960), _book('c7c6', 40)],
        ),
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.map((c) => c.moveSan), ['c5', 'c6']);
    });

    test('a move too thinly played is still dropped', () async {
      resetNodeIds();
      final node = _oppNodeAfterE4();

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(
            maiaMinProb: 0.05,
            coverMinProb: 0.0,
            oppMaxChildren: 0,
            oppMassTarget: 0.0,
          ),
          node: node,
          pool: FakeStockfishPool(),
          source: _FakeMoveSource(const {}),
          // 4 games is a one-off, not a system.
          masterBook: (_) => [_book('c7c5', 996), _book('c7c6', 4)],
        ),
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.map((c) => c.moveSan), ['c5']);
    });

    test('the root fans out past the child cap and the mass target', () async {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      )..searchPriority = 1.0;

      await NodeExpander.forRun(
        _run(
          // Caps that would keep two moves at any other node.
          config: _base.copyWith(
            playAsWhite: false,
            oppMaxChildren: 2,
            oppMassTarget: 0.5,
            coverMinProb: 0.0,
          ),
          node: root,
          pool: FakeStockfishPool(),
          source: _FakeMoveSource(const {}),
          masterBook: (_) => [
            _book('e2e4', 500),
            _book('d2d4', 400),
            _book('c2c4', 60),
            _book('g1f3', 40),
          ],
        ),
      ).expandOpponentMove(root, FrontierQueue(bestFirst: true));

      expect(root.children.map((c) => c.moveSan), ['e4', 'd4', 'c4', 'Nf3']);
    });

    test('away from the root the caps still bind', () async {
      resetNodeIds();
      final node = _oppNodeAfterE4();

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(
            oppMaxChildren: 2,
            oppMassTarget: 1.0,
            coverMinProb: 0.0,
          ),
          node: node,
          pool: FakeStockfishPool(),
          source: _FakeMoveSource(const {}),
          masterBook: (_) => [
            _book('c7c5', 500),
            _book('e7e5', 400),
            _book('e7e6', 60),
            _book('c7c6', 40),
          ],
        ),
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.map((c) => c.moveSan), ['c5', 'e5']);
    });
  });

  group('master practice is read past the branching cap', () {
    // The bug: the book stopped being *read* at maxPly because that is where
    // it stops *choosing*. Every line's game counts went blank at that ply,
    // and the export reported the branching cap as the end of theory.
    test('a non-branching node still records the book stats', () async {
      resetNodeIds();
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        // At the branching cap: the book no longer picks replies here.
        ply: 12,
        isWhiteToMove: false,
      )..searchPriority = 1.0;
      final source = _FakeMoveSource({
        kFenAfterE4: const [DbMove(uci: 'c7c5', stmCp: -20)],
      });

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(maxPly: 12),
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (fen) => fen == kFenAfterE4
              ? [_book('c7c5', 600), _book('e7e5', 400)]
              : const [],
        ),
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      // The position's own total, so the annotation knows this is still
      // deep in practice rather than past the end of it.
      expect(node.totalGames, 1000);
      // And the move played from it carries its own count.
      expect(node.children.single.moveSan, 'c5');
      expect(node.children.single.totalGames, 600);
      expect(node.children.single.lastPlayedYear, 2024);
    });

    test('our move records them too', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [DbMove(uci: 'e2e4', stmCp: 30)],
      });

      await NodeExpander.forRun(
        _run(
          config: _base,
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (_) => [_book('e2e4', 700), _book('d2d4', 300)],
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.totalGames, 1000);
      expect(node.children.single.totalGames, 700);
    });

    test('an existing count is never rewritten', () async {
      resetNodeIds();
      final node = _ourRoot()..setLichessStats(400, 200, 100);
      final source = _FakeMoveSource({
        kStandardStartFen: const [DbMove(uci: 'e2e4', stmCp: 30)],
      });

      await NodeExpander.forRun(
        _run(
          config: _base,
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (_) => [_book('e2e4', 700), _book('d2d4', 300)],
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      // The fan-out set 700 games for the move that reached this node; the
      // position total (1000) must not replace it, or `[%games]` changes
      // meaning partway through a file.
      expect(node.totalGames, 700);
    });

    test('a position the book has never seen records nothing', () async {
      resetNodeIds();
      final node = _ourRoot();
      final source = _FakeMoveSource({
        kStandardStartFen: const [DbMove(uci: 'e2e4', stmCp: 30)],
      });

      await NodeExpander.forRun(
        _run(
          config: _base,
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          masterBook: (_) => const [],
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(node.totalGames, 0);
      expect(node.children.single.totalGames, 0);
    });
  });

  group('depth', () {
    test('every line may run to the tail cap, in practice or out', () async {
      final config = _base.copyWith(maxPly: 20, bookTailMaxPly: 40);
      final run = _run(
        config: config,
        node: _ourRoot(),
        pool: FakeStockfishPool(),
        masterBook: (fen) =>
            fen == kFenAfterE4 ? [_book('c7c5', 500)] : const [],
      );

      // maxPly caps branching, not length: truncating a line still in
      // master practice would cut off exactly the deepest theory the book
      // exists to carry.
      expect(run.plyCapAt(kFenAfterE4, 20), 40);
      expect(run.plyCapAt(kFenAfterD4, 20), 40);
      expect(run.plyCapAt(kFenAfterD4, 4), 40);
    });

    test('past the branching cap, master practice stops branching', () async {
      resetNodeIds();
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 20,
        isWhiteToMove: false,
      )..searchPriority = 1.0;
      final source = _FakeMoveSource({
        kFenAfterE4: const [
          DbMove(uci: 'c7c5', stmCp: -20),
          DbMove(uci: 'e7e5', stmCp: -14),
        ],
      });

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(maxPly: 20),
          node: node,
          pool: FakeStockfishPool(),
          source: source,
          // Plenty of practice here — but the branching budget is spent.
          masterBook: (_) => [_book('c7c5', 600), _book('e7e5', 400)],
        ),
      ).expandOpponentMove(node, FrontierQueue(bestFirst: true));

      expect(node.children.map((c) => c.moveSan), ['e5']);
    });

    test('a tail cap below the branching cap is ignored', () {
      const config = TreeBuildConfig(
        startFen: kStandardStartFen,
        playAsWhite: true,
        maxPly: 30,
        bookTailMaxPly: 10,
      );
      expect(config.resolvedBookTailMaxPly, 30);
    });
  });

  test('the book never runs the verification pass', () {
    expect(_base.copyWith(verifyFinal: true).runsVerification, isFalse);
    expect(
      _base
          .copyWith(buildMode: BuildMode.stockfishExpectimax, verifyFinal: true)
          .runsVerification,
      isTrue,
    );
  });

  test('the engine is only spun up when the book asks for a floor', () {
    expect(_base.usesStockfish, isFalse);
    expect(_base.copyWith(bookEngineFallback: true).usesStockfish, isTrue);
    // Either way the expander, not the build loop, resolves our-move evals —
    // a second lookup per position would double the book's request cost.
    expect(_base.expanderSuppliesOurMoveEval, isTrue);
  });
}
