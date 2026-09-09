/// [ChessDbBookExpander] — the paths `chessdb_book_expander_test.dart`
/// leaves open: the engine floor at a Black-to-move node (three sign
/// conversions in a row), and a reply-window tie where the database knows
/// only one of the candidates' resulting positions.
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
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

class _FakeMoveSource implements ExternalMoveProvider {
  _FakeMoveSource(this.byFen);

  final Map<String, List<DbMove>> byFen;

  @override
  Future<DbMoveList> lookupMoves(String fen) async {
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
  required _FakeMoveSource source,
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

void main() {
  test(
    'the engine floor at a Black-to-move node speaks side-to-move',
    () async {
      resetNodeIds();
      // Our repertoire is Black; ChessDB has never seen the position after
      // 1.e4 (it has, of course — but the fake says otherwise).
      final node = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
      )..searchPriority = 1.0;
      final stats = BuildStats();
      final pool = FakeStockfishPool()
        ..discoveryByFen[kFenAfterE4] = DiscoveryResult(
          lines: [
            // White-POV: -15 is good for Black.
            discoveryLine(pvNumber: 1, cpWhite: -15, pv: ['e7e5']),
          ],
        );

      await NodeExpander.forRun(
        _run(
          config: _base.copyWith(playAsWhite: false, bookEngineFallback: true),
          node: node,
          pool: pool,
          source: _FakeMoveSource(const {}),
          stats: stats,
        ),
      ).expandOurMove(node, FrontierQueue(bestFirst: true));

      expect(stats.bookEngineFallbacks, 1);
      // Black to move at the node: +15 for the side to move.
      expect(node.engineEvalCp, 15);
      final e5 = node.children.single;
      expect(e5.moveSan, 'e5');
      // White to move after ...e5: back to White's -15.
      expect(e5.engineEvalCp, -15);
      expect(e5.evalForUs(false), 15);
    },
  );

  test(
    'a reply-window tie is settled among the candidates the database can '
    'compare; an unknown one drops out even when masters prefer it',
    () async {
      resetNodeIds();
      final node = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
      )..searchPriority = 1.0;
      // dartchess writes no en-passant square when no capture is possible.
      const afterE4 =
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final source = _FakeMoveSource({
        kStandardStartFen: const [
          DbMove(uci: 'e2e4', stmCp: 30),
          DbMove(uci: 'd2d4', stmCp: 30),
        ],
        // 1.e4 is known (three level replies); 1.d4 is not known at all.
        afterE4: const [
          DbMove(uci: 'e7e5', stmCp: -30),
          DbMove(uci: 'c7c5', stmCp: -31),
          DbMove(uci: 'e7e6', stmCp: -35),
        ],
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

      // Only e4 could be compared, so e4 it is — master practice never
      // gets a vote once the reply count has produced a single winner.
      expect(node.children.single.moveSan, 'e4');
    },
  );
}
