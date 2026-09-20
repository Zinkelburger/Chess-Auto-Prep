import '../fen.dart';
import 'backup.dart';
import 'eval.dart';

/// A move as the two notations the search needs: standard UCI to identify it
/// (it is what the opponent model is keyed by, and what ties are broken on)
/// and SAN to write it into a PGN.
final class MoveRef {
  const MoveRef({required this.uci, required this.san});

  final String uci;
  final String san;

  @override
  String toString() => san;
}

/// How a game ended. Checkmate is decided before any draw claim, so a mate
/// that happens to be the third repetition of a position is still a mate.
enum TerminalKind {
  checkmate,
  stalemate,
  insufficientMaterial,
  fiftyMoveRule,
  repetition,
}

/// One position of the search tree, together with everything below it.
///
/// Nodes are values: expanding one builds a new tree that shares the parts
/// that did not change. They are never merged by position, because a node is
/// its whole path from the root — two identical placements reached different
/// ways have different repetition histories and different half-move clocks,
/// so the same move can be a draw down one path and not down the other.
sealed class SearchNode {
  const SearchNode({required this.fen, required this.evalForUs});

  final Fen fen;

  /// The fixed-depth evaluation of [fen], already converted to the repertoire
  /// side's point of view. Every position the search creates carries one: the
  /// loss window compares siblings by it, ties are ordered by it, a horizon
  /// leaf is worth [expectedScore] of it, and an unexpanded node borrows it
  /// as a provisional value.
  final Eval evalForUs;

  /// What the node is worth and how far that could still move. A leaf works
  /// it out from what it already knows; a node with children keeps the
  /// backed-up value it was built with.
  Valuation get valuation;
}

/// The game is over here, so the value is chess, not an estimate.
final class TerminalNode extends SearchNode {
  const TerminalNode({
    required super.fen,
    required super.evalForUs,
    required this.kind,
    required this.ourTurn,
  });

  final TerminalKind kind;

  /// Whether the repertoire side is the one with no move to make, which is
  /// what turns a checkmate into a win or a loss.
  final bool ourTurn;

  @override
  Valuation get valuation =>
      Valuation.exact(kind == TerminalKind.checkmate ? (ourTurn ? 0 : 1) : 0.5);
}

/// The horizon: the search stops looking and takes the engine's word for the
/// position, turned into an expected score by [expectedScore].
final class HorizonNode extends SearchNode {
  const HorizonNode({required super.fen, required super.evalForUs});

  @override
  Valuation get valuation => Valuation.exact(expectedScore(evalForUs));
}

/// A position the search has reached but not expanded.
///
/// Every leaf of a cancelled or budget-stopped build is one of these, and so
/// is every legal move of ours while the loss window is deciding which to
/// keep. Its value is only the engine's opinion, so its bounds stay the whole
/// interval: the subtree below it could still turn out to be anything.
final class FrontierNode extends SearchNode {
  const FrontierNode({required super.fen, required super.evalForUs})
    : evaluated = true;

  /// A position a build attached and stopped before scoring.
  ///
  /// No engine has said anything about it, which is not the same as an
  /// engine calling it level: a build that resumes evaluates this node,
  /// while a node scored zero is one it would never look at again. It is
  /// worth the neutral score until someone scores it.
  const FrontierNode.unevaluated({required super.fen})
    : evaluated = false,
      super(evalForUs: const Eval(0));

  /// Whether [evalForUs] is an engine's score or the neutral stand-in.
  final bool evaluated;

  @override
  Valuation get valuation => Valuation.provisional(expectedScore(evalForUs));
}

/// One of our moves that the loss window admitted, and where it leads.
final class CandidateMove {
  const CandidateMove({required this.move, required this.child});

  final MoveRef move;
  final SearchNode child;

  /// What the loss window compared and what breaks a tie: the fixed-depth
  /// evaluation of the position this move reaches, from our side.
  Eval get evalForUs => child.evalForUs;
}

/// Our turn: we choose, so the node is worth the best move we may play.
///
/// [candidates] are the moves the engine-loss window admitted, in the order
/// we would play them, so `candidates.first` is the repertoire move. The
/// order is the one [compareCandidates] defines and it is the same comparison
/// the value comes from: what the node is worth and what it exports can never
/// disagree.
final class OurNode extends SearchNode {
  const OurNode._({
    required super.fen,
    required super.evalForUs,
    required this.valuation,
    required this.candidates,
  });

  /// Orders [candidates] by preference and takes their best value. At least
  /// one candidate is required: a position with no legal move is a terminal.
  factory OurNode.over({
    required Fen fen,
    required Eval evalForUs,
    required List<CandidateMove> candidates,
  }) {
    final ordered = [...candidates]..sort(compareCandidates);
    return OurNode._(
      fen: fen,
      evalForUs: evalForUs,
      valuation: maxOver(ordered.map((c) => c.child.valuation)),
      candidates: List.unmodifiable(ordered),
    );
  }

  @override
  final Valuation valuation;

  final List<CandidateMove> candidates;

  /// The move this node plays in the exported repertoire.
  CandidateMove get chosen => candidates.first;
}

/// Ranks two of our moves: the one worth more first, then the one the engine
/// likes more, then by UCI, then by SAN.
///
/// The last two decide nothing about chess; they are there so that two moves
/// the search cannot tell apart still come out in the same order on every
/// machine and every run.
int compareCandidates(CandidateMove a, CandidateMove b) {
  var order = b.child.valuation.value.compareTo(a.child.valuation.value);
  if (order == 0) order = b.evalForUs.cp.compareTo(a.evalForUs.cp);
  if (order == 0) order = a.move.uci.compareTo(b.move.uci);
  if (order == 0) order = a.move.san.compareTo(b.move.san);
  return order;
}

/// A reply the opponent model gives positive probability, and where it leads.
final class ReplyMove {
  const ReplyMove({
    required this.move,
    required this.probability,
    required this.child,
  });

  final MoveRef move;

  /// The reply's share of the opponent's policy over the legal moves, so the
  /// shares of one node sum to one.
  final double probability;

  final SearchNode child;
}

/// The opponent's turn: we do not choose, so the node is worth the average of
/// the replies weighted by how likely each one is.
final class OpponentNode extends SearchNode {
  const OpponentNode._({
    required super.fen,
    required super.evalForUs,
    required this.valuation,
    required this.replies,
  });

  /// Every reply with positive probability is kept; there is no cap on how
  /// many, and rare replies are not dropped to save work.
  factory OpponentNode.over({
    required Fen fen,
    required Eval evalForUs,
    required List<ReplyMove> replies,
  }) => OpponentNode._(
    fen: fen,
    evalForUs: evalForUs,
    valuation: weightedSum(
      replies.map((r) => (r.probability, r.child.valuation)),
    ),
    replies: List.unmodifiable(replies),
  );

  @override
  final Valuation valuation;

  final List<ReplyMove> replies;
}
