import '../pgn/game_tree.dart';
import 'search_node.dart';

/// The repertoire the search chose, as a game tree ready to be written as a
/// chapter.
///
/// At one of our nodes it writes the one move we picked — the same move the
/// node's value came from, so what we play and what we claimed it was worth
/// can never drift apart — and at one of the opponent's it writes every reply
/// the model gave positive probability, each as its own variation. The walk
/// stops at a finished game, at the horizon, and at anything the search did
/// not expand.
///
/// Nothing is folded, dropped or reordered on the way out. Two lines that
/// reach the same position stay two lines, because they are two different
/// things to have learned, and a rare reply is written exactly like a common
/// one.
GameTree exportRepertoire(SearchNode root) =>
    GameTree(rootFen: root.fen, children: _linesFrom(root));

List<MoveNode> _linesFrom(SearchNode node) => switch (node) {
  OurNode(:final chosen) => [_moveNode(chosen.move, chosen.child)],
  OpponentNode(:final replies) => [
    for (final reply in replies) _moveNode(reply.move, reply.child),
  ],
  TerminalNode() || HorizonNode() || FrontierNode() => const [],
};

MoveNode _moveNode(MoveRef move, SearchNode child) => MoveNode(
  san: move.san,
  uci: move.uci,
  fen: child.fen,
  children: _linesFrom(child),
);
