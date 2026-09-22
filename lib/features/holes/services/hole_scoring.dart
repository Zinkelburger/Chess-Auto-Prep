/// Pure selection helpers for the hole hunt: which attacker positions and
/// candidate moves get engine time, and the sign conventions behind a
/// trick's numbers. Kept free of engine and widget dependencies so they are
/// unit-testable.
///
/// Reach propagation down the tree is the shared
/// `features/audit/services/repertoire_walk.dart`; finding-level ranking is
/// `features/audit/services/exploit_ranking.dart`, shared with the report
/// panel.
///
/// Sign conventions: engine discovery scores are White-normalized; every
/// attacker-perspective number in this file goes through
/// [TrickCandidateMetrics.fromWhiteCp] — the single flip point.
library;

import '../../../chess_core/moves/opening_graph.dart';
import '../../audit/services/engine_position_probe.dart';

/// An attacker-to-move position collected during the walk, candidate for
/// trick discovery. [reach] is the summed probability of reaching this
/// position across transpositions (owner branching attenuates, attacker
/// steering does not).
class TrickTarget {
  final OpeningNodeView node;
  final List<String> movePath;
  double reach;

  TrickTarget({
    required this.node,
    required this.movePath,
    required this.reach,
  });

  String get fen => node.fen;
}

/// Top-[k] targets by reach (descending, stable).
List<TrickTarget> selectTopTargets(List<TrickTarget> targets, int k) {
  if (k <= 0) return const [];
  final indexed = targets.asMap().entries.toList();
  indexed.sort((a, b) {
    final c = b.value.reach.compareTo(a.value.reach);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return indexed.take(k).map((e) => e.value).toList();
}

/// Attacker-perspective evals for one candidate — the sign-flip choke
/// point. All downstream arithmetic (cost, gap, net gain) lives here.
class TrickCandidateMetrics {
  /// Raw eval after the candidate move, attacker perspective.
  final int candidateRawCp;

  /// Raw eval of the engine-best move, attacker perspective.
  final int bestRawCp;

  const TrickCandidateMetrics({
    required this.candidateRawCp,
    required this.bestRawCp,
  });

  factory TrickCandidateMetrics.fromWhiteCp({
    required int candidateWhiteCp,
    required int bestWhiteCp,
    required bool attackerIsWhite,
  }) {
    int toAttacker(int whiteCp) => attackerIsWhite ? whiteCp : -whiteCp;
    return TrickCandidateMetrics(
      candidateRawCp: toAttacker(candidateWhiteCp),
      bestRawCp: toAttacker(bestWhiteCp),
    );
  }

  /// What the candidate concedes objectively vs the best move (>= 0 when
  /// the discovery ordering invariant holds).
  int get objectiveCostCp => bestRawCp - candidateRawCp;

  /// Practical eval after the candidate minus its raw eval — how much the
  /// opponent bleeds in expectation from this position.
  int practicalGapCp(int probeExpectedCp) => probeExpectedCp - candidateRawCp;

  /// Practical eval after the candidate minus the BEST move's raw eval —
  /// what playing the trick gains over just playing the engine move.
  int netGainCp(int probeExpectedCp) => probeExpectedCp - bestRawCp;
}

/// A candidate move at a target, ready for prescreening and probing.
class TrickCandidate {
  final TrickTarget target;
  final String san;
  final String uci;
  final String bestSan;
  final TrickCandidateMetrics metrics;

  /// True when the move is not among the tree's own children at the target.
  final bool isNovelty;

  const TrickCandidate({
    required this.target,
    required this.san,
    required this.uci,
    required this.bestSan,
    required this.metrics,
    required this.isNovelty,
  });
}

/// Window-filter the MultiPV lines at [target] into candidates.
///
/// Keeps lines whose objective cost is within [windowCp], capped at
/// [maxPerNode] in engine order (best first) — except that an in-tree move
/// inside the window is always kept, even past the cap, so the hunt can
/// score moves the source already plays.
List<TrickCandidate> selectCandidates({
  required TrickTarget target,
  required List<DiscoveredCandidate> lines,
  required Set<String> inTreeSans,
  required bool attackerIsWhite,
  required int windowCp,
  required int maxPerNode,
}) {
  if (lines.isEmpty || maxPerNode <= 0) return const [];
  final bestWhiteCp = lines.first.whiteCp;
  final bestSan = lines.first.san;

  final result = <TrickCandidate>[];
  for (final line in lines) {
    final metrics = TrickCandidateMetrics.fromWhiteCp(
      candidateWhiteCp: line.whiteCp,
      bestWhiteCp: bestWhiteCp,
      attackerIsWhite: attackerIsWhite,
    );
    if (metrics.objectiveCostCp > windowCp) continue;

    final isInTree = inTreeSans.contains(line.san);
    if (result.length >= maxPerNode && !isInTree) continue;

    result.add(
      TrickCandidate(
        target: target,
        san: line.san,
        uci: line.uci,
        bestSan: bestSan,
        metrics: metrics,
        isNovelty: !isInTree,
      ),
    );
  }
  return result;
}

/// Prescreen score deciding which candidates get an expectimax probe.
///
/// Reach dominates (it is the dominant term of the final exploit score);
/// objective cost gets a half-weight linear discount because every cp of
/// cost eats a cp of net-gain headroom.
double prescreenScore(TrickCandidate c, {required int windowCp}) {
  if (windowCp <= 0) return c.target.reach;
  final cost = c.metrics.objectiveCostCp.clamp(0, windowCp);
  return c.target.reach * (1.0 - 0.5 * cost / windowCp);
}

/// Top-[budget] candidates by prescreen score (descending, stable).
List<TrickCandidate> selectProbeCandidates(
  List<TrickCandidate> candidates, {
  required int budget,
  required int windowCp,
}) {
  if (budget <= 0) return const [];
  final indexed = candidates.asMap().entries.toList();
  indexed.sort((a, b) {
    final c = prescreenScore(
      b.value,
      windowCp: windowCp,
    ).compareTo(prescreenScore(a.value, windowCp: windowCp));
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return indexed.take(budget).map((e) => e.value).toList();
}
