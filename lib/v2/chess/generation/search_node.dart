import '../fen.dart';
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
  const SearchNode({required this.fen, required Eval? evalForUs})
    : _eval = evalForUs;

  final Fen fen;

  /// What an engine said about [fen], or null when none has.
  final Eval? _eval;

  /// The fixed-depth evaluation of [fen], already converted to the repertoire
  /// side's point of view. Every position the search creates carries one: the
  /// loss window compares siblings by it, ties are ordered by it, a horizon
  /// leaf is worth [expectedScore] of it, and an unexpanded node borrows it
  /// as a provisional value. A node nothing has scored is worth level until
  /// something does.
  Eval get evalForUs => _eval ?? const Eval(0);

  /// Whether an engine has scored [fen] at all.
  ///
  /// A saved tree leaves the score out of a node its build attached and never
  /// reached, and a builder that resumes scores exactly those nodes. Level
  /// and unscored are different facts about a position, so they are different
  /// values here and the file keeps them apart.
  bool get evaluated => _eval != null;

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
///
/// One with no score at all is a node a build attached and stopped before
/// reaching, which is not an engine calling the position level.
final class FrontierNode extends SearchNode {
  const FrontierNode({required super.fen, required super.evalForUs});

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
    required Eval? evalForUs,
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
    required Eval? evalForUs,
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

/// What a node is worth, and how far the answer could still move.
///
/// [value] is an expected score in [0, 1] from the repertoire side's point of
/// view: 1 is a win for us, 0.5 a draw, 0 a loss. [lower] and [upper] bound
/// what [value] could become once everything below the node is expanded, so
/// equal bounds mean the subtree is finished and the value is final. They
/// bound this model — the engine's estimates and the opponent model are taken
/// as given — not real-world chess.
final class Valuation {
  const Valuation({
    required this.value,
    required this.lower,
    required this.upper,
  });

  /// A node with nothing left to expand: its value cannot move.
  const Valuation.exact(this.value) : lower = value, upper = value;

  /// A node the search has not expanded: the engine's estimate, and no
  /// information at all about where its subtree would take it.
  const Valuation.provisional(this.value) : lower = 0, upper = 1;

  final double value;
  final double lower;
  final double upper;

  bool get isExact => lower == upper;

  @override
  String toString() =>
      'Valuation(${value.toStringAsFixed(4)}, [$lower, $upper])';
}

/// Our turn: we play whichever admitted move is worth most, so the node is
/// worth the best of [children] and its bounds are the best of theirs.
///
/// Example: children worth 0.7 (exact) and 0.4 in [0, 1] back up to a node
/// worth 0.7 in [0.7, 1] — expanding the unfinished sibling can only replace
/// the leader, never leave us with less than the 0.7 we already have.
Valuation maxOver(Iterable<Valuation> children) {
  var best = children.first;
  var lower = best.lower;
  var upper = best.upper;
  for (final child in children.skip(1)) {
    if (child.value > best.value) best = child;
    if (child.lower > lower) lower = child.lower;
    if (child.upper > upper) upper = child.upper;
  }
  return Valuation(value: best.value, lower: lower, upper: upper);
}

/// The opponent's turn: we get the average of the replies, weighted by how
/// likely the opponent model says each one is.
///
/// [replies] pairs each probability with the reply's valuation, and the
/// probabilities must already sum to one. Example: a 0.75 reply worth 0.4 and
/// a 0.25 reply worth 0.8 back up to 0.75·0.4 + 0.25·0.8 = 0.5. Bounds are
/// the same sum taken over the replies' bounds, which is why an opponent node
/// narrows as its replies do rather than only when the last one finishes.
Valuation weightedSum(Iterable<(double, Valuation)> replies) {
  var value = 0.0;
  var lower = 0.0;
  var upper = 0.0;
  var mass = 0.0;
  for (final (probability, reply) in replies) {
    value += probability * reply.value;
    lower += probability * reply.lower;
    upper += probability * reply.upper;
    mass += probability;
  }
  // The shares come from Policy.sharesOver, which normalises them, so this
  // is a check on that promise rather than something to correct for: a sum
  // that has drifted means the caller weighted the replies itself, and
  // silently clamping the answer back into [0, 1] would hide it.
  assert(
    (mass - 1).abs() < 1e-9,
    'the replies of one node must share one whole move, not $mass',
  );
  return Valuation(value: value, lower: lower, upper: upper);
}
