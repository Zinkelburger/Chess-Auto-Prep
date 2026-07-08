/// Dirichlet smoothing of opponent move probabilities with a Maia prior.
///
/// Raw database frequencies are the right opponent model when a position has
/// thousands of games and pure noise when it has nine.  Instead of a hard
/// DB→Maia fallback cliff, blend counts with Maia's policy as a Dirichlet
/// prior worth [priorGames] virtual games:
///
///     p(move) = (count(move) + λ · maia(move)) / (N + λ)
///
/// With N ≫ λ the data dominates and the prior vanishes; at N = 0 this
/// degrades continuously to the pure Maia policy.  Moves that appear only in
/// the Maia policy (zero DB games) are included with count 0, so a plausible
/// human move missing from a sparsely covered position still gets mass.
///
/// Probabilities stay RAW (Σ p ≤ 1 over the emitted subset downstream) —
/// smoothing replaces the counts-to-probability estimate, not the expectimax
/// tail-term convention.
library;

/// One opponent candidate with a smoothed probability estimate.
class SmoothedMove {
  final String uci;

  /// SAN if the source provided it; empty means the caller must derive it.
  final String san;

  /// Smoothed play probability.
  final double probability;

  /// Raw DB game count (0 for Maia-only moves).
  final int games;

  /// DB win/draw stats carried through for node enrichment (0 when absent).
  final int whiteWins;
  final int blackWins;
  final int draws;

  const SmoothedMove({
    required this.uci,
    required this.san,
    required this.probability,
    required this.games,
    this.whiteWins = 0,
    this.blackWins = 0,
    this.draws = 0,
  });
}

/// One raw DB move observation.
class ObservedMove {
  final String uci;
  final String san;
  final int games;
  final int whiteWins;
  final int blackWins;
  final int draws;

  const ObservedMove({
    required this.uci,
    required this.san,
    required this.games,
    this.whiteWins = 0,
    this.blackWins = 0,
    this.draws = 0,
  });
}

/// Above this many real games per virtual-prior game the prior's weight is
/// under ~1% and a Maia inference buys nothing — skip it.
const int kSmoothingSkipFactor = 100;

/// Whether smoothing is worth a Maia inference for a position with
/// [totalGames] observations under a [priorGames] prior.
bool smoothingWorthwhile(int totalGames, double priorGames) {
  if (priorGames <= 0) return false;
  return totalGames < kSmoothingSkipFactor * priorGames;
}

/// Blend [observed] DB counts (over [totalGames] position visits) with the
/// [maiaPolicy] prior at weight [priorGames], returning candidates sorted by
/// smoothed probability, highest first.
///
/// Pass an empty [maiaPolicy] (or `priorGames <= 0`) to get pure normalized
/// frequencies — the function then reduces to `count / N`.
List<SmoothedMove> smoothOpponentMoves({
  required List<ObservedMove> observed,
  required int totalGames,
  required Map<String, double> maiaPolicy,
  required double priorGames,
}) {
  final n = totalGames > 0
      ? totalGames
      : observed.fold(0, (sum, m) => sum + m.games);
  final lambda = priorGames > 0 && maiaPolicy.isNotEmpty ? priorGames : 0.0;
  final denom = n + lambda;
  if (denom <= 0) return const [];

  final out = <SmoothedMove>[];
  final seen = <String>{};

  for (final m in observed) {
    seen.add(m.uci);
    final prior = lambda > 0 ? (maiaPolicy[m.uci] ?? 0.0) : 0.0;
    out.add(SmoothedMove(
      uci: m.uci,
      san: m.san,
      probability: (m.games + lambda * prior) / denom,
      games: m.games,
      whiteWins: m.whiteWins,
      blackWins: m.blackWins,
      draws: m.draws,
    ));
  }

  if (lambda > 0) {
    for (final entry in maiaPolicy.entries) {
      if (seen.contains(entry.key)) continue;
      final p = lambda * entry.value / denom;
      if (p <= 0) continue;
      out.add(SmoothedMove(
        uci: entry.key,
        san: '',
        probability: p,
        games: 0,
      ));
    }
  }

  out.sort((a, b) => b.probability.compareTo(a.probability));
  return out;
}
