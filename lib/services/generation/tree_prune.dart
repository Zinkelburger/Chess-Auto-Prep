/// Pure tree-shaping helpers extracted from `tree_build_service.dart` (WS-A / B6).
///
/// These operate only on the [BuildTree]/[BuildTreeNode] structures passed in —
/// no engine, network, or service state — so their behavior can be locked in
/// with unit tests that construct trees directly.
library;

import 'dart:collection';

import '../../models/build_tree_node.dart';

/// Remove every subtree whose root was flagged [PruneReason.evalTooLow],
/// keeping the rest of the tree intact. Also drops the removed nodes from the
/// tree's [BuildTree.nodeIndex] and refreshes [BuildTree.totalNodes].
///
/// Returns the number of nodes removed (including descendants).
int pruneEvalTooLow(BuildTree tree) {
  final removed = _pruneRecursive(tree, tree.root);
  if (removed > 0) {
    tree.totalNodes = tree.root.countSubtree();
  }
  return removed;
}

int _pruneRecursive(BuildTree tree, BuildTreeNode node) {
  int removed = 0;
  for (int i = node.children.length - 1; i >= 0; i--) {
    final child = node.children[i];
    if (child.pruneReason == PruneReason.evalTooLow) {
      final subtreeSize = child.countSubtree();
      _removeFromIndex(tree, child);
      node.children.removeAt(i);
      removed += subtreeSize;
    } else {
      removed += _pruneRecursive(tree, child);
    }
  }
  return removed;
}

void _removeFromIndex(BuildTree tree, BuildTreeNode node) {
  tree.nodeIndex.remove(node.nodeId);
  for (final child in node.children) {
    _removeFromIndex(tree, child);
  }
}

/// Scale cumulative probability through a canonical subtree when a
/// transposition path reaches it with a higher probability (matches the C
/// `propagate_higher_cumP`).
///
/// No-op when [newCumP] is not greater than the canonical node's current
/// cumulative probability. Otherwise the node and all descendants are scaled
/// by the same ratio; unexplored leaves whose scaled probability clears
/// [minProbability] are appended to [queue] for (re)exploration.
void propagateHigherCumP(
  BuildTreeNode canonical,
  double newCumP,
  double minProbability,
  Queue<BuildTreeNode> queue,
) {
  if (newCumP <= canonical.cumulativeProbability) return;
  final ratio = newCumP / canonical.cumulativeProbability;
  canonical.cumulativeProbability = newCumP;
  _propagateCumPRecursive(canonical, ratio, minProbability, queue);
}

void _propagateCumPRecursive(
  BuildTreeNode node,
  double ratio,
  double minProbability,
  Queue<BuildTreeNode> queue,
) {
  for (final child in node.children) {
    child.cumulativeProbability *= ratio;
    if (child.children.isNotEmpty) {
      _propagateCumPRecursive(child, ratio, minProbability, queue);
    } else if (!child.explored &&
        child.cumulativeProbability >= minProbability) {
      queue.add(child);
    }
  }
}
