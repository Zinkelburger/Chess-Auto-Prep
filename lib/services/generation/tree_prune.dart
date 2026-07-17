/// Pure tree-shaping helpers extracted from `tree_build_service.dart`.
///
/// These operate only on the [BuildTree]/[BuildTreeNode] structures passed in —
/// no engine, network, or service state — so their behavior can be locked in
/// with unit tests that construct trees directly.
library;

import '../../models/build_tree_node.dart';
import 'frontier_queue.dart';

/// Snapshot of an eval-too-low subtree root taken just before deletion, so
/// debug output can answer "was line X generated and then pruned?".
class PrunedLine {
  final int nodeId;
  final int ply;
  final String lineSan;
  final String fen;
  final int? engineEvalCp;
  final int? pruneEvalCp;
  final double cumulativeProbability;
  final int subtreeNodes;

  PrunedLine.fromNode(BuildTreeNode node)
    : nodeId = node.nodeId,
      ply = node.ply,
      lineSan = node.getLineSan().join(' '),
      fen = node.fen,
      engineEvalCp = node.engineEvalCp,
      pruneEvalCp = node.pruneEvalCp,
      cumulativeProbability = node.cumulativeProbability,
      subtreeNodes = node.countSubtree();

  Map<String, dynamic> toJson() => {
    'node_id': nodeId,
    'ply': ply,
    'line_san': lineSan,
    'fen': fen,
    if (engineEvalCp != null) 'engine_eval_cp': engineEvalCp,
    if (pruneEvalCp != null) 'prune_eval_cp': pruneEvalCp,
    'cumulative_probability': cumulativeProbability,
    'subtree_nodes': subtreeNodes,
  };
}

/// Remove every subtree whose root was flagged [PruneReason.evalTooLow],
/// keeping the rest of the tree intact. Also drops the removed nodes from the
/// tree's [BuildTree.nodeIndex] and refreshes [BuildTree.totalNodes].
///
/// When [removedLines] is provided, a [PrunedLine] snapshot of each removed
/// subtree root is appended to it (descendants are not recorded separately).
///
/// Returns the number of nodes removed (including descendants).
int pruneEvalTooLow(BuildTree tree, {List<PrunedLine>? removedLines}) {
  final removed = _pruneRecursive(tree, tree.root, removedLines);
  if (removed > 0) {
    tree.totalNodes = tree.root.countSubtree();
  }
  return removed;
}

int _pruneRecursive(
  BuildTree tree,
  BuildTreeNode node,
  List<PrunedLine>? removedLines,
) {
  int removed = 0;
  for (int i = node.children.length - 1; i >= 0; i--) {
    final child = node.children[i];
    if (child.pruneReason == PruneReason.evalTooLow) {
      removedLines?.add(PrunedLine.fromNode(child));
      final subtreeSize = child.countSubtree();
      _removeFromIndex(tree, child);
      node.children.removeAt(i);
      removed += subtreeSize;
    } else {
      removed += _pruneRecursive(tree, child, removedLines);
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
  FrontierQueue queue,
) {
  if (newCumP <= canonical.cumulativeProbability) return;
  final old = canonical.cumulativeProbability;
  canonical.cumulativeProbability = newCumP;
  if (old <= 0.0) {
    // Ratio would be Inf; rebuild descendant cumPs from edge probabilities
    // so a zero→positive transposition still widens the frontier. Seed the
    // priority baseline with the canonical's new cumP (its own discount-from-
    // root is unrecoverable from the zeroed state, but relative discounts
    // *within* the subtree are preserved from here down).
    _rebuildCumPFromEdges(
      canonical,
      canonical.cumulativeProbability,
      minProbability,
      queue,
    );
    return;
  }
  final ratio = newCumP / old;
  _propagateCumPRecursive(canonical, ratio, minProbability, queue);
}

void _propagateCumPRecursive(
  BuildTreeNode node,
  double ratio,
  double minProbability,
  FrontierQueue queue,
) {
  for (final child in node.children) {
    child.cumulativeProbability *= ratio;
    if (child.searchPriority >= 0.0) child.searchPriority *= ratio;
    if (child.children.isNotEmpty) {
      _propagateCumPRecursive(child, ratio, minProbability, queue);
    } else if (!child.explored &&
        child.cumulativeProbability >= minProbability) {
      // If the leaf is still queued, [FrontierQueue.add] re-sifts it in place
      // for its just-raised searchPriority instead of adding a duplicate; if
      // it was already popped (below-floor) it is re-enqueued.
      queue.add(child);
    }
  }
}

/// Absolute cumP assign when the canonical had zero/negative probability
/// (ratio scaling is undefined). Uses each child's [BuildTreeNode.moveProbability]
/// as the parent→child edge weight.
///
/// [parentSearchPriority] is the rebuilt priority of [node]; each child's
/// priority is `parent × edge × searchPriorityDiscount`, mirroring how the
/// finite-ratio path multiplies rather than overwriting — so our-move
/// alternatives keep their discount instead of getting the raw (undiscounted)
/// cumP, which would let them jump the frontier ahead of higher-value lines.
void _rebuildCumPFromEdges(
  BuildTreeNode node,
  double parentSearchPriority,
  double minProbability,
  FrontierQueue queue,
) {
  for (final child in node.children) {
    final edge = child.moveProbability;
    child.cumulativeProbability = node.cumulativeProbability * edge;
    if (child.searchPriority >= 0.0) {
      child.searchPriority =
          parentSearchPriority * edge * child.searchPriorityDiscount;
    }
    // Fall back to cumP for legacy nodes that never carried a priority.
    final childSearchPriority = child.searchPriority >= 0.0
        ? child.searchPriority
        : child.cumulativeProbability;
    if (child.children.isNotEmpty) {
      _rebuildCumPFromEdges(child, childSearchPriority, minProbability, queue);
    } else if (!child.explored &&
        child.cumulativeProbability >= minProbability) {
      queue.add(child);
    }
  }
}
