import 'search_node.dart';
import 'terminal.dart';

/// A node while the search is still working: the leaf it is for now, and
/// what it turned into once it was expanded.
///
/// This is the one thing in the search that changes after it is made. The
/// queue has to hand out places in the tree before their subtrees exist, and
/// the tree it hands to the caller is built from these at the end, so nothing
/// mutable ever leaves the run.
final class PendingNode {
  PendingNode(this.path, this.leaf);

  final SearchPath path;
  final SearchNode leaf;

  Expansion? expansion;
}

/// What one expanded node turned into: the moves we may play, or the replies
/// the opponent may answer with.
sealed class Expansion {
  const Expansion();

  Iterable<PendingNode> get children;
}

final class OurMoves extends Expansion {
  const OurMoves(this.admitted);

  final List<(MoveRef, PendingNode)> admitted;

  @override
  Iterable<PendingNode> get children => admitted.map((entry) => entry.$2);
}

final class Replies extends Expansion {
  const Replies(this.replies);

  final List<(MoveRef, double, PendingNode)> replies;

  @override
  Iterable<PendingNode> get children => replies.map((entry) => entry.$3);
}

/// Builds the immutable tree out of the finished scaffolding, bottom up. A
/// node nothing was expanded into stays the leaf it already was.
SearchNode assembleTree(PendingNode pending) => switch (pending.expansion) {
  null => pending.leaf,
  OurMoves(:final admitted) => OurNode.over(
    fen: pending.leaf.fen,
    evalForUs: pending.leaf.evalForUs,
    candidates: [
      for (final (move, child) in admitted)
        CandidateMove(move: move, child: assembleTree(child)),
    ],
  ),
  Replies(:final replies) => OpponentNode.over(
    fen: pending.leaf.fen,
    evalForUs: pending.leaf.evalForUs,
    replies: [
      for (final (move, probability, child) in replies)
        ReplyMove(
          move: move,
          probability: probability,
          child: assembleTree(child),
        ),
    ],
  ),
};
