/// Shared trap-score formula for opponent-move nodes.
///
/// Single implementation of the analysis previously duplicated in
/// [ExpectimaxCalculator.computeTrapScores] and `TrapExtractor._collectTraps`:
///
///   trap = clamp(evalDiff / 200, 0, 1) * highestProb * findability
///
/// where `evalDiff` is the difference between the best move's eval and the
/// most popular move's eval, both from the mover's (opponent's) perspective,
/// and `findability` discounts traps whose punishing reply is a move a human
/// at our level rarely finds (`min(1, maiaFrequency / pRef)`, FlawChess-style
/// — a trap whose refutation is inhuman is not a practical trap).  The
/// factor is 1.0 when no [findabilityPRef] is supplied or Maia data is
/// absent.
library;

import '../../models/build_tree_node.dart';
import '../../utils/eval_constants.dart';
import '../../utils/findability.dart';

/// Result of analyzing an opponent-move node's children for a trap.
class TrapScoreAnalysis {
  /// Child with the highest move probability.
  final BuildTreeNode mostPopular;

  /// Child with the best eval from the mover's (opponent's) perspective.
  final BuildTreeNode bestMove;

  /// [mostPopular]'s move probability.
  final double highestProb;

  /// Best child eval from the mover's perspective (`-child.engineEvalCp`).
  final int bestEvalForMover;

  /// Most popular child eval from the mover's perspective.
  /// Equals [bestEvalForMover] when [popularIsBest].
  final int popularEvalForMover;

  /// Our punishing reply under [mostPopular]: the repertoire move when
  /// selection has run, else the highest-eval-for-us reply.  Null when
  /// [mostPopular] has no evaluated children (unexpanded leaf).
  final BuildTreeNode? refutation;

  /// `min(1, refutation.maiaFrequency / pRef)` — 1.0 when findability
  /// weighting is off, Maia data is absent, or there is no [refutation].
  final double refutationFindability;

  /// `clamp((best - popular) / 200, 0, 1) * highestProb *
  /// refutationFindability`; 0.0 when the popular move is also the best
  /// move.
  final double trapScore;

  bool get popularIsBest => identical(mostPopular, bestMove);

  const TrapScoreAnalysis({
    required this.mostPopular,
    required this.bestMove,
    required this.highestProb,
    required this.bestEvalForMover,
    required this.popularEvalForMover,
    required this.trapScore,
    this.refutation,
    this.refutationFindability = 1.0,
  });
}

/// Compute the trap score at an opponent-move [node].
///
/// Returns null in exactly the cases both original derivations skipped:
/// fewer than two children, no child with probability > 0, no child with an
/// engine eval, or a most-popular child without an engine eval (unless it is
/// also the best move, in which case the score is 0.0 by definition).
///
/// [findabilityPRef] (from `pRefForElo(config.maiaElo)`) enables the
/// punishment-findability discount; null keeps the raw formula.
TrapScoreAnalysis? analyzeTrapScore(
  BuildTreeNode node, {
  double? findabilityPRef,
}) {
  if (node.children.length < 2) return null;

  BuildTreeNode? mostPopular;
  BuildTreeNode? bestMove;
  var highestProb = 0.0;
  var bestEval = kWorstEvalCp;

  for (final child in node.children) {
    if (child.moveProbability > highestProb) {
      highestProb = child.moveProbability;
      mostPopular = child;
    }
    if (child.hasEngineEval) {
      final evalForMover = -child.engineEvalCp!;
      if (evalForMover > bestEval) {
        bestEval = evalForMover;
        bestMove = child;
      }
    }
  }

  if (mostPopular == null || bestMove == null) return null;

  if (identical(mostPopular, bestMove)) {
    // Opponents mostly play the best move here — nothing to trap.
    return TrapScoreAnalysis(
      mostPopular: mostPopular,
      bestMove: bestMove,
      highestProb: highestProb,
      bestEvalForMover: bestEval,
      popularEvalForMover: bestEval,
      trapScore: 0.0,
    );
  }

  if (!mostPopular.hasEngineEval) return null;
  final popularEval = -mostPopular.engineEvalCp!;

  var evalDiff = (bestEval - popularEval).toDouble();
  if (evalDiff < 0) evalDiff = 0;
  var trap = evalDiff / 200.0;
  if (trap > 1.0) trap = 1.0;
  trap *= highestProb;

  final refutation = _bestReply(mostPopular);
  var findability = 1.0;
  if (findabilityPRef != null && refutation != null) {
    findability = findabilityFactor(refutation.maiaFrequency, findabilityPRef);
    trap *= findability;
  }

  return TrapScoreAnalysis(
    mostPopular: mostPopular,
    bestMove: bestMove,
    highestProb: highestProb,
    bestEvalForMover: bestEval,
    popularEvalForMover: popularEval,
    trapScore: trap,
    refutation: refutation,
    refutationFindability: findability,
  );
}

/// Our punishing reply under the opponent's popular blunder: the selected
/// repertoire move when present (post-selection), else the highest
/// eval-for-us reply.  [popular]'s children are our-move nodes, so their
/// `engineEvalCp` (side-to-move POV of the position after our reply, i.e.
/// the opponent's) negates to our perspective — mirroring the mover-eval
/// convention above.
BuildTreeNode? _bestReply(BuildTreeNode popular) {
  BuildTreeNode? best;
  var bestEvalUs = kWorstEvalCp;
  for (final reply in popular.children) {
    if (reply.isRepertoireMove) return reply;
    if (!reply.hasEngineEval) continue;
    final evalUs = -reply.engineEvalCp!;
    if (evalUs > bestEvalUs) {
      bestEvalUs = evalUs;
      best = reply;
    }
  }
  return best;
}
