/// Pure scoring/ranking helpers for the hole hunt. Kept free of engine and
/// widget dependencies so they are unit-testable.
library;

import '../../audit/models/audit_finding.dart';

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

/// exploitScore = reach probability × gain (cp). A null/zero probability
/// contributes nothing — unreachable holes don't rank.
double exploitScoreOf({double? cumProb, required int gainCp}) {
  final p = cumProb ?? 0.0;
  return p * gainCp;
}

/// Sort findings by [AuditFinding.exploitScore] descending, falling back to
/// cumulative probability, then to insertion order (stable).
List<AuditFinding> rankByExploitScore(List<AuditFinding> findings) {
  final indexed = findings.asMap().entries.toList();
  indexed.sort((a, b) {
    final sa = a.value.exploitScore ?? 0.0;
    final sb = b.value.exploitScore ?? 0.0;
    if (sa != sb) return sb.compareTo(sa);
    final pa = a.value.cumulativeProbability ?? 0.0;
    final pb = b.value.cumulativeProbability ?? 0.0;
    if (pa != pb) return pb.compareTo(pa);
    return a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
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
