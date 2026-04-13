/// Ease calculation for [BuildTreeNode] trees.
///
/// Walks the tree and computes ease at every node that has evaluated
/// children.  Ease measures how likely the side to move is to find a
/// good move — high ease means popular replies are close to optimal.
///
/// All evals must already be on the nodes (from the build phase).
library;

import 'dart:math' as math;

import '../../models/build_tree_node.dart';
import '../../utils/ease_utils.dart';

/// Compute ease scores on every applicable node in the tree.
/// Returns the number of nodes that received an ease value.
int calculateTreeEase(BuildTree tree) {
  return _easeRecursive(tree.root);
}

int _easeRecursive(BuildTreeNode node) {
  int count = 0;
  if (node.children.isNotEmpty) {
    final ease = _nodeEase(node);
    if (ease != null) {
      node.ease = ease;
      count++;
    }
  }
  for (final child in node.children) {
    count += _easeRecursive(child);
  }
  return count;
}

double? _nodeEase(BuildTreeNode node) {
  if (node.children.isEmpty) return null;

  // Find the best eval from the parent's perspective.
  // child.engineEvalCp is side-to-move; negating gives parent's perspective.
  int bestEval = -100000;
  bool hasEvals = false;
  for (final child in node.children) {
    if (child.hasEngineEval) {
      final evalForUs = -child.engineEvalCp!;
      if (evalForUs > bestEval) bestEval = evalForUs;
      hasEvals = true;
    }
  }
  if (!hasEvals) return null;

  final qMax = scoreToQ(bestEval);
  double sumWeightedRegret = 0.0;
  for (final child in node.children) {
    if (!child.hasEngineEval) continue;
    if (child.moveProbability < 0.01) continue;
    final qVal = scoreToQ(-child.engineEvalCp!);
    final regret = math.max(0.0, qMax - qVal);
    sumWeightedRegret += math.pow(child.moveProbability, kEaseBeta) * regret;
  }

  double ease = 1.0 - math.pow(sumWeightedRegret / 2.0, kEaseAlpha);
  return ease.clamp(0.0, 1.0);
}
