/// Pure walk helpers for the hole hunt: which leaves the trap pass probes,
/// and how reach probability flows down the tree. Kept free of engine and
/// widget dependencies so they are unit-testable.
///
/// Finding-level scoring and ranking is
/// `features/audit/services/exploit_ranking.dart` — shared with the trick
/// hunt, which has no other business with this file.
library;

/// A repertoire leaf collected during the walk, candidate for the
/// expectimax trap pass.
class LeafEntry {
  final String fen;
  final List<String> movePath;
  final double cumProb;

  const LeafEntry({
    required this.fen,
    required this.movePath,
    required this.cumProb,
  });
}

/// Top-[k] leaves by cumulative reach probability (descending, stable).
List<LeafEntry> selectTopLeaves(List<LeafEntry> leaves, int k) {
  if (k <= 0) return const [];
  final indexed = leaves.asMap().entries.toList();
  indexed.sort((a, b) {
    final c = b.value.cumProb.compareTo(a.value.cumProb);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return indexed.take(k).map((e) => e.value).toList();
}

/// Reach-probability propagation for the hole hunt.
///
/// Deliberate inversion of the audit's rule: the ATTACKER steers the game
/// (their branches keep the parent's probability), while the repertoire
/// OWNER chooses among their own alternatives — so only owner-to-move
/// branching attenuates, by the child's share of games at the parent.
double childProbability({
  required bool isOwnerTurn,
  required int childGames,
  required int parentTotalGames,
  required double cumProb,
}) {
  if (!isOwnerTurn || parentTotalGames <= 0) return cumProb;
  return cumProb * (childGames / parentTotalGames);
}
