/// Expectimax value propagation for [BuildTree].
///
/// Bottom-up post-order DFS that computes a practical win probability V
/// at every node.  Ports the C tree builder's
/// `calculate_expectimax_recursive`.
library;

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
  ///
  /// Two-pass expectimax (matches C `tree_calculate_expectimax`): the first
  /// pass gives every canonical node a correct value; the second pass ensures
  /// transposition leaves that were visited before their canonical in pass 1
  /// now find the canonical ready and propagate the corrected value upward.
  int calculate(BuildTree tree) {
    _expectimaxRecursive(tree.root);
    return _expectimaxRecursive(tree.root);
  }

  /// Leaf value: blend engine win probability toward a neutral 0.5 prior
  /// using `leafConfidence`.  Matches C `leaf_value()`.
  ///
  ///   V = lc * wp(eval_for_us) + (1 - lc) * 0.5
  ///
  /// Returns 0.5 (neutral/"unknown") when no engine eval is available.
  double _leafValue(BuildTreeNode node) {
    if (!node.hasEngineEval) return 0.5;
    final lc = config.leafConfidence.clamp(0.0, 1.0);
    final cpUs = node.evalForUs(config.playAsWhite);
    return lc * winProbability(cpUs) + (1.0 - lc) * 0.5;
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

    // Subtree ply count + opponent plies (diagnostics)
    if (node.children.isEmpty) {
      node.subtreePly = 0;
      node.subtreeOppPlies = 0;
    } else {
      int maxPly = 0;
      int maxOpp = 0;
      for (final child in node.children) {
        final childPly = child.subtreePly + 1;
        if (childPly > maxPly) maxPly = childPly;

        int opp = child.subtreeOppPlies;
        if (!isOurMove) opp += 1;
        if (opp > maxOpp) maxOpp = opp;
      }
      node.subtreePly = maxPly;
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
        node.subtreePly = canonical.subtreePly;
        node.subtreeOppPlies = canonical.subtreeOppPlies;
        node.hasExpectimax = true;
        count++;
        return count;
      }
    }

    if (node.children.isEmpty) {
      node.expectimaxValue = _leafValue(node);
    } else if (isOurMove) {
      final best = scoreOurMoveChildren(node);
      node.expectimaxValue = best?.expectimaxValue ?? _leafValue(node);
    } else {
      // Opponent move — raw probabilities with tail term for uncovered mass.
      //   V = Σ p_i · V(child_i)  +  (1 − Σ p_i) · leaf_value(this)
      double covered = 0.0;
      double v = 0.0;
      for (final child in node.children) {
        if (!child.hasExpectimax) continue;
        covered += child.moveProbability;
        v += child.moveProbability * child.expectimaxValue;
      }

      if (covered > 1.0) covered = 1.0;
      if (covered < 0.0) covered = 0.0;

      final tail = 1.0 - covered;
      if (tail > 0.0) {
        v += tail * _leafValue(node);
      }

      node.expectimaxValue = v;
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
  /// passing the eval-loss filter, with optional novelty boost.
  /// Falls back to all children if none pass the filter.
  ///
  /// Novelty boost (matches C `score_our_move_children`):
  ///   novelty = 1 - child.totalGames/parent.totalGames (if both have games)
  ///           = 1 - child.maiaFrequency (if Maia data available)
  ///   v_adj = v * (1 + nw * novelty)
  /// The stored expectimax_value uses the *unboosted* child V.
  ScoredChild? scoreOurMoveChildren(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    int bestChildCp = -100000;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs > bestChildCp) bestChildCp = cpUs;
    }

    final nw = config.noveltyWeight / 100.0;

    double bestV = -1.0;
    BuildTreeNode? bestChild;
    int passing = 0;

    for (final child in node.children) {
      if (!child.hasExpectimax) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs < bestChildCp - config.maxEvalLossCp) continue;
      passing++;

      double v = child.expectimaxValue;
      if (nw > 0.0) {
        double novelty = 0.0;
        if (node.totalGames > 0 && child.totalGames > 0) {
          novelty = 1.0 - child.totalGames / node.totalGames;
        } else if (child.maiaFrequency >= 0.0) {
          novelty = 1.0 - child.maiaFrequency;
        }
        if (novelty < 0.0) novelty = 0.0;
        v *= (1.0 + nw * novelty);
      }

      if (v > bestV) {
        bestV = v;
        bestChild = child;
      }
    }

    // Fallback: all filtered → consider all children
    if (passing == 0) {
      for (final child in node.children) {
        if (!child.hasExpectimax) continue;
        double v = child.expectimaxValue;
        if (nw > 0.0) {
          double novelty = 0.0;
          if (node.totalGames > 0 && child.totalGames > 0) {
            novelty = 1.0 - child.totalGames / node.totalGames;
          } else if (child.maiaFrequency >= 0.0) {
            novelty = 1.0 - child.maiaFrequency;
          }
          if (novelty < 0.0) novelty = 0.0;
          v *= (1.0 + nw * novelty);
        }
        if (v > bestV) {
          bestV = v;
          bestChild = child;
        }
      }
    }

    if (bestChild == null) return null;
    return ScoredChild(
      child: bestChild,
      expectimaxValue: bestChild.expectimaxValue,
    );
  }

  /// Compute trap scores on opponent-move nodes throughout the tree.
  /// Trap score measures how often opponents play suboptimal moves:
  ///   trap = clamp(eval_diff / 200, 0, 1) * highest_probability
  /// where eval_diff is the difference between the best move's eval
  /// and the most popular move's eval (from the mover's perspective).
  void computeTrapScores(BuildTreeNode root) {
    _trapScoreRecursive(root);
  }

  void _trapScoreRecursive(BuildTreeNode node) {
    for (final child in node.children) {
      _trapScoreRecursive(child);
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    if (isOurMove || node.children.length < 2) return;

    BuildTreeNode? mostPopular;
    BuildTreeNode? bestMove;
    double highestProb = 0.0;
    int bestEval = -100000;

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

    if (mostPopular == null || bestMove == null) return;
    if (mostPopular == bestMove) {
      node.trapScore = 0.0;
      return;
    }

    if (!mostPopular.hasEngineEval) return;
    final popularEval = -mostPopular.engineEvalCp!;

    double evalDiff = (bestEval - popularEval).toDouble();
    if (evalDiff < 0) evalDiff = 0;
    double trap = evalDiff / 200.0;
    if (trap > 1.0) trap = 1.0;
    trap *= highestProb;

    node.trapScore = trap;
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
