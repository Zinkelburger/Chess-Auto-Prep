/// Shared trap-score formula for opponent-move nodes.
///
/// Single implementation of the analysis previously duplicated in
/// [ExpectimaxCalculator.computeTrapScores] and `TrapExtractor._collectTraps`:
///
///   trap = clamp(evalDiff / 200, 0, 1) * highestProb
///
/// where `evalDiff` is the difference between the best move's eval and the
/// most popular move's eval, both from the mover's (opponent's) perspective.
library;

import '../../models/build_tree_node.dart';
import '../../utils/eval_constants.dart';

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

  /// `clamp((best - popular) / 200, 0, 1) * highestProb`;
  /// 0.0 when the popular move is also the best move.
  final double trapScore;

  bool get popularIsBest => identical(mostPopular, bestMove);

  const TrapScoreAnalysis({
    required this.mostPopular,
    required this.bestMove,
    required this.highestProb,
    required this.bestEvalForMover,
    required this.popularEvalForMover,
    required this.trapScore,
  });
}

/// Compute the trap score at an opponent-move [node].
///
/// Returns null in exactly the cases both original derivations skipped:
/// fewer than two children, no child with probability > 0, no child with an
/// engine eval, or a most-popular child without an engine eval (unless it is
/// also the best move, in which case the score is 0.0 by definition).
TrapScoreAnalysis? analyzeTrapScore(BuildTreeNode node) {
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

  return TrapScoreAnalysis(
    mostPopular: mostPopular,
    bestMove: bestMove,
    highestProb: highestProb,
    bestEvalForMover: bestEval,
    popularEvalForMover: popularEval,
    trapScore: trap,
  );
}
