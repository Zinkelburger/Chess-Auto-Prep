/// Expectimax value propagation for [BuildTree].
///
/// Bottom-up post-order DFS that computes a practical win probability V
/// at every node.  Ports the C tree builder's
/// `calculate_expectimax_recursive`.
library;

import 'dart:math' as math;

import '../../models/build_tree_node.dart';
import '../../utils/ease_utils.dart' show winProbability;
import 'fen_map.dart';
import 'generation_config.dart';

class ExpectimaxCalculator {
  final TreeBuildConfig config;
  final FenMap? fenMap;

  ExpectimaxCalculator({required this.config, this.fenMap});

  /// Run expectimax calculation on the full tree. Returns the count of nodes
  /// that received a value.
  int calculate(BuildTree tree) {
    return _expectimaxRecursive(tree.root);
  }

  int _expectimaxRecursive(BuildTreeNode node) {
    int count = 0;

    for (final child in node.children) {
      count += _expectimaxRecursive(child);
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;

    if (!isOurMove && node.children.isNotEmpty) {
      _computeLocalCpl(node);
    }

    // Subtree depth + opponent plies (diagnostics)
    if (node.children.isEmpty) {
      node.subtreeDepth = 0;
      node.subtreeOppPlies = 0;
    } else {
      int maxSd = 0;
      int maxOpp = 0;
      for (final child in node.children) {
        final sd = child.subtreeDepth + 1;
        if (sd > maxSd) maxSd = sd;

        int opp = child.subtreeOppPlies;
        if (!isOurMove) opp += 1;
        if (opp > maxOpp) maxOpp = opp;
      }
      node.subtreeDepth = maxSd;
      node.subtreeOppPlies = maxOpp;
    }

    // Transposition leaves: borrow V from canonical node
    if (node.children.isEmpty && fenMap != null) {
      final canonical = fenMap!.getCanonical(node.fen);
      if (canonical != null &&
          canonical != node &&
          canonical.hasExpectimax &&
          canonical.children.isNotEmpty) {
        node.expectimaxValue = canonical.expectimaxValue;
        node.localCpl = canonical.localCpl;
        node.subtreeDepth = canonical.subtreeDepth;
        node.subtreeOppPlies = canonical.subtreeOppPlies;
        node.hasExpectimax = true;
        count++;
        return count;
      }
    }

    final alpha = config.trickWeight / 100.0;
    final alphaEff = alpha * math.pow(config.depthDiscount, node.depth.toDouble());

    if (node.children.isEmpty) {
      // Leaf: V = leaf_conf × wp(eval_for_us)
      final cpUs = node.evalForUs(config.playAsWhite);
      node.expectimaxValue = config.leafConfidence * winProbability(cpUs);
    } else if (isOurMove) {
      // Our move: V = max(V_child) among eval-loss-filtered candidates
      final best = scoreOurMoveChildren(node);
      node.expectimaxValue = best?.expectimaxValue ?? 0.0;
    } else {
      // Opponent move: blend minimax and expectimax
      final cpUs = node.evalForUs(config.playAsWhite);
      final vEngine = winProbability(cpUs);

      double probSum = 0.0;
      for (final child in node.children) {
        probSum += child.moveProbability;
      }

      double vHuman = 0.0;
      for (final child in node.children) {
        if (!child.hasExpectimax) continue;
        final normProb = probSum > 0.0
            ? child.moveProbability / probSum
            : child.moveProbability;
        vHuman += normProb * child.expectimaxValue;
      }

      node.expectimaxValue = (1.0 - alphaEff) * vEngine + alphaEff * vHuman;
    }

    node.hasExpectimax = true;
    count++;
    return count;
  }

  /// Local CPL: probability-weighted centipawn loss relative to the
  /// opponent's best available move (display only).
  void _computeLocalCpl(BuildTreeNode node) {
    if (node.children.isEmpty) return;

    int bestOppCp = 100000;
    bool hasAny = false;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      if (child.engineEvalCp! < bestOppCp) bestOppCp = child.engineEvalCp!;
      hasAny = true;
    }
    if (!hasAny) return;

    double sum = 0.0;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      if (child.moveProbability < 0.01) continue;
      int delta = child.engineEvalCp! - bestOppCp;
      if (delta < 0) delta = 0;
      sum += child.moveProbability * delta.toDouble();
    }
    node.localCpl = sum;
  }

  /// Pick the child with the highest expectimax value among candidates
  /// passing the eval-loss filter.  Falls back to all children if none pass.
  ScoredChild? scoreOurMoveChildren(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    int bestChildCp = -100000;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs > bestChildCp) bestChildCp = cpUs;
    }

    double bestV = -1.0;
    BuildTreeNode? bestChild;
    int passing = 0;

    for (final child in node.children) {
      if (!child.hasExpectimax) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs < bestChildCp - config.maxEvalLossCp) continue;
      passing++;
      if (child.expectimaxValue > bestV) {
        bestV = child.expectimaxValue;
        bestChild = child;
      }
    }

    // Fallback: all filtered → consider all children
    if (passing == 0) {
      for (final child in node.children) {
        if (!child.hasExpectimax) continue;
        if (child.expectimaxValue > bestV) {
          bestV = child.expectimaxValue;
          bestChild = child;
        }
      }
    }

    if (bestChild == null) return null;
    return ScoredChild(
      child: bestChild,
      expectimaxValue: bestV,
    );
  }
}

class ScoredChild {
  final BuildTreeNode child;
  final double expectimaxValue;

  const ScoredChild({
    required this.child,
    required this.expectimaxValue,
  });
}
