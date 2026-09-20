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
