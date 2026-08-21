/// Pure selection/scoring helpers for the trick hunt. Kept free of engine
/// and widget dependencies so they are unit-testable.
///
/// Sign conventions: engine discovery scores are White-normalized; every
/// trickster-perspective number in this file goes through
/// [TrickCandidateMetrics.fromWhiteCp] — the single flip point.
library;

import 'dart:collection';

import '../../../models/opening_tree.dart';
import '../../../utils/fen_utils.dart';
import '../../holes/services/hole_scoring.dart';

/// A trickster-to-move position collected during the walk, candidate for
/// engine discovery. [reach] is the summed probability of reaching this
/// position across transpositions (owner branching attenuates, trickster
/// steering does not — same rule as the hole hunt).
class TrickTarget {
  final OpeningTreeNode node;
  final List<String> movePath;
  double reach;

  TrickTarget({
    required this.node,
    required this.movePath,
    required this.reach,
  });

  String get fen => node.fen;
}

/// Collect every trickster-to-move position within [maxPly] — childless
/// leaves included, which is where a hunt extends past the recorded games.
///
/// Engine-free and synchronous. Reach uses the hole hunt's inverted rule
/// ([childProbability]): the trickster steers, so only owner-to-move
/// branching attenuates, by each child's share of games at the parent.
({List<TrickTarget> targets, int nodesWalked}) collectTrickTargets(
  OpeningTreeNode root, {
  required bool playerIsWhite,
  required int maxPly,
}) {
  final targets = <TrickTarget>[];
  int walked = 0;
  final queue = Queue<_TrickWalkEntry>();
  queue.add(
    _TrickWalkEntry(
      node: root,
      movePath: root.getMovePath(),
      ply: 0,
      cumProb: 1.0,
    ),
  );

  while (queue.isNotEmpty) {
    final entry = queue.removeFirst();
    final node = entry.node;
    if (entry.ply > maxPly) continue;
    walked++;

    final isWhiteTurn = isWhiteToMove(node.fen);
    final isOwnerTurn = isWhiteTurn == playerIsWhite;

    if (!isOwnerTurn) {
      targets.add(
        TrickTarget(node: node, movePath: entry.movePath, reach: entry.cumProb),
      );
    }

    final parentTotal = node.children.values.fold<int>(
      0,
      (sum, c) => sum + c.gamesPlayed,
    );
    for (final childEntry in node.children.entries) {
      queue.add(
        _TrickWalkEntry(
          node: childEntry.value,
          movePath: [...entry.movePath, childEntry.key],
          ply: entry.ply + 1,
          cumProb: childProbability(
            isOwnerTurn: isOwnerTurn,
            childGames: childEntry.value.gamesPlayed,
            parentTotalGames: parentTotal,
            cumProb: entry.cumProb,
          ),
        ),
      );
    }
  }
  return (targets: targets, nodesWalked: walked);
}

class _TrickWalkEntry {
  final OpeningTreeNode node;
  final List<String> movePath;
  final int ply;
  final double cumProb;

  const _TrickWalkEntry({
    required this.node,
    required this.movePath,
    required this.ply,
    required this.cumProb,
  });
}

/// Merge targets that are the same position (4-field FEN identity), summing
/// reach (clamped to 1.0) onto the first-seen representative. Preserves
/// first-seen order.
List<TrickTarget> dedupTargets(Iterable<TrickTarget> targets) {
  final byFen = <String, TrickTarget>{};
  final order = <String>[];
  for (final t in targets) {
    final key = normalizeFen(t.fen);
    final existing = byFen[key];
    if (existing == null) {
      byFen[key] = t;
      order.add(key);
    } else {
      existing.reach = (existing.reach + t.reach).clamp(0.0, 1.0);
    }
  }
  return [for (final k in order) byFen[k]!];
}

/// Targets that get engine discovery: reach floor, then top-[maxNodes] by
/// reach (descending, stable).
List<TrickTarget> selectDiscoveryTargets(
  List<TrickTarget> targets, {
  required double minReachProb,
  required int maxNodes,
}) {
  if (maxNodes <= 0) return const [];
  final eligible = targets.where((t) => t.reach >= minReachProb).toList();
  final indexed = eligible.asMap().entries.toList();
  indexed.sort((a, b) {
    final c = b.value.reach.compareTo(a.value.reach);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return indexed.take(maxNodes).map((e) => e.value).toList();
}

/// One MultiPV line at a trick target, SAN-resolved by the caller. Lists of
/// these must keep engine order: best line for the side to move first —
/// and the side to move at a trick target is the trickster.
class DiscoveredCandidate {
  final String uci;
  final String san;
  final int whiteCp;

  const DiscoveredCandidate({
    required this.uci,
    required this.san,
    required this.whiteCp,
  });
}

/// Trickster-perspective evals for one candidate — the sign-flip choke
/// point. All downstream arithmetic (cost, gap, net gain) lives here.
class TrickCandidateMetrics {
  /// Raw eval after the candidate move, trickster perspective.
  final int candidateRawCp;

  /// Raw eval of the engine-best move, trickster perspective.
  final int bestRawCp;

  const TrickCandidateMetrics({
    required this.candidateRawCp,
    required this.bestRawCp,
  });

  factory TrickCandidateMetrics.fromWhiteCp({
    required int candidateWhiteCp,
    required int bestWhiteCp,
    required bool tricksterIsWhite,
  }) {
    int toTrickster(int whiteCp) => tricksterIsWhite ? whiteCp : -whiteCp;
    return TrickCandidateMetrics(
      candidateRawCp: toTrickster(candidateWhiteCp),
      bestRawCp: toTrickster(bestWhiteCp),
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
  required bool tricksterIsWhite,
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
      tricksterIsWhite: tricksterIsWhite,
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
