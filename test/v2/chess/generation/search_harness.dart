import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_sources.dart';

export 'scripted_sources.dart';

/// White king and pawn against a bare black king: six legal moves for White,
/// few enough to write down.
const kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

/// The opponent has one king move everywhere below [kingAndPawn], so the
/// tests can say what our side does without also modelling a reply.
const oneReply = ScriptedPolicy({'e8d8': 1});

const foolsMate =
    'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';
const afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

Future<SearchResult> searchFrom(
  String fen, {
  required SearchConfig config,
  PositionEvaluator? evaluator,
  OpponentPolicy policy = oneReply,
  CancelSignal? isCancelled,
  LastPly? lastPly,
}) => buildSearchTree(
  root: positionOf(fen),
  config: config,
  evaluator: evaluator ?? ScriptedEvaluator(),
  policy: policy,
  isCancelled: isCancelled ?? () => false,
  lastPly: lastPly,
);

SearchNode treeOf(SearchResult result) => switch (result) {
  SearchComplete(:final tree) => tree,
  SearchIncomplete(:final tree) => tree,
  _ => fail('expected a tree, got $result'),
};

/// How many nodes the finished tree holds, the root among them, which is
/// what the node budget counts.
int nodesIn(SearchNode node) => switch (node) {
  OurNode(:final candidates) =>
    1 + candidates.fold(0, (sum, c) => sum + nodesIn(c.child)),
  OpponentNode(:final replies) =>
    1 + replies.fold(0, (sum, r) => sum + nodesIn(r.child)),
  _ => 1,
};

/// Two mates for us, one slightly slower than the other.
///
/// Scores are reported from the side to move, and after one of our moves that
/// is the opponent, so a mate for us is a large negative number here.
ScriptedEvaluator matesForUs() {
  final root = positionOf(kingAndPawn);
  return ScriptedEvaluator(
    scores: {
      afterUci(root, 'e2e4').fen: -9800,
      afterUci(root, 'e2e3').fen: -9700,
    },
  );
}
