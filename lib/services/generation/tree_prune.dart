/// Pure tree-shaping helpers extracted from `tree_build_service.dart`.
///
/// These operate only on the [BuildTree]/[BuildTreeNode] structures passed in —
/// no engine, network, or service state — so their behavior can be locked in
/// with unit tests that construct trees directly.
library;

import '../../models/build_tree_node.dart';
import 'fen_map.dart';
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
/// One move is always left behind at a node where **we** are to move. If
/// every reply we have there is below the window, removing them all would
/// leave the repertoire with no answer to a move the opponent has already
/// played, which is not an answer it is allowed to give — so the least bad
/// of them survives as a leaf and the line ends on our move.
///
/// This matters even with a sane window. The flag is applied at build depth,
/// which is shallow: on a real Benko tree a depth-14 search read a position
/// 28cp worse than depth 20 did, and the deletion is irreversible — the
/// depth-20 verification pass that would have exonerated it runs afterwards
/// and cannot resurrect what is already gone.
///
/// When [removedLines] is provided, a [PrunedLine] snapshot of each removed
/// subtree root is appended to it (descendants are not recorded separately).
///
/// Returns the number of nodes removed (including descendants).
int pruneEvalTooLow(
  BuildTree tree, {
  required bool playAsWhite,
  List<PrunedLine>? removedLines,
}) {
  final removed = _pruneRecursive(
    tree,
    tree.root,
    removedLines,
    playAsWhite: playAsWhite,
  );
  if (removed > 0) {
    tree.totalNodes = tree.root.countSubtree();
  }
  return removed;
}

int _pruneRecursive(
  BuildTree tree,
  BuildTreeNode node,
  List<PrunedLine>? removedLines, {
  required bool playAsWhite,
}) {
  // Our turn here, and nothing we can play survives the window: keep the
  // best of a bad set rather than answer with silence. Decided before any
  // removal so the pass is idempotent — a second run reaches the same
  // conclusion about the same node.
  BuildTreeNode? reprieved;
  if (node.children.isNotEmpty && node.isWhiteToMove == playAsWhite) {
    final doomed = node.children
        .where((c) => c.pruneReason == PruneReason.evalTooLow)
        .toList();
    if (doomed.length == node.children.length) {
      reprieved = doomed.reduce(
        (a, b) => b.evalForUs(playAsWhite) > a.evalForUs(playAsWhite) ? b : a,
      );
    }
  }

  int removed = 0;
  for (int i = node.children.length - 1; i >= 0; i--) {
    final child = node.children[i];
    if (child.pruneReason == PruneReason.evalTooLow &&
        !identical(child, reprieved)) {
      removedLines?.add(PrunedLine.fromNode(child));
      final subtreeSize = child.countSubtree();
      _removeFromIndex(tree, child);
      node.children.removeAt(i);
      removed += subtreeSize;
    } else {
      removed += _pruneRecursive(
        tree,
        child,
        removedLines,
        playAsWhite: playAsWhite,
      );
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

/// Below this, an arrival adds nothing worth walking a subtree for.
const double _kArrivalEpsilon = 1e-12;

/// Add a new arrival's reach probability to a canonical subtree.
///
/// A position reached by several move orders is reached with the **sum** of
/// their probabilities — they are disjoint ways for the game to get there.
/// When a transposition leaf with reach [delta] is registered against
/// [canonical], the canonical and every descendant gain `delta × (product
/// of edge probabilities from the canonical down)`, which is exactly the
/// extra mass each of them now carries.  Adding a delta rather than
/// rescaling by a ratio keeps this correct when a descendant already holds
/// arrivals of its own: those are left alone instead of being scaled too.
///
/// Where the walk meets a *registered* transposition leaf (one the build has
/// already closed against its canonical), the leaf's own increment is
/// forwarded into that canonical in turn — chains of transpositions stay
/// consistent to any depth.  A chain that loops back onto a position already
/// being updated (a repetition) stops there; [active] carries that guard.
/// Unexplored frontier leaves are not forwarded: they add their full reach,
/// increment included, when the build processes them.
///
/// Unexplored leaves whose reach clears [minProbability] are (re)queued;
/// [FrontierQueue.add] re-sifts a leaf already waiting rather than
/// duplicating it.  Search priorities scale with their node's reach so the
/// frontier order follows the new mass.
void addArrivalCumP(
  BuildTreeNode canonical,
  double delta,
  double minProbability,
  FrontierQueue queue, {
  FenMap? fenMap,
  Set<String>? active,
}) {
  if (delta <= _kArrivalEpsilon) return;
  final chain = active ?? <String>{};
  final key = canonicalizeFen(canonical.fen);
  if (!chain.add(key)) return; // repetition: already being updated above
  _addReach(canonical, delta);
  _addArrivalRecursive(
    canonical,
    delta,
    effectiveSearchPriority(canonical),
    minProbability,
    queue,
    fenMap,
    chain,
  );
  chain.remove(key);
}

/// Add [delta] to [node]'s reach and scale its priority to match.
void _addReach(BuildTreeNode node, double delta) {
  final old = node.cumulativeProbability;
  node.cumulativeProbability = old + delta;
  if (node.searchPriority >= 0.0 && old > 0.0) {
    node.searchPriority *= node.cumulativeProbability / old;
  }
}

void _addArrivalRecursive(
  BuildTreeNode node,
  double delta,
  double parentSearchPriority,
  double minProbability,
  FrontierQueue queue,
  FenMap? fenMap,
  Set<String> chain,
) {
  for (final child in node.children) {
    final childDelta = delta * child.moveProbability;
    if (childDelta <= _kArrivalEpsilon) continue;
    final hadReach = child.cumulativeProbability > 0.0;
    _addReach(child, childDelta);
    if (!hadReach && child.searchPriority >= 0.0) {
      // Nothing to scale from: rebuild the priority the way expansion
      // assigns it, so an alternative keeps its discount.
      child.searchPriority =
          parentSearchPriority *
          child.moveProbability *
          child.searchPriorityDiscount;
    }
    if (child.children.isNotEmpty) {
      _addArrivalRecursive(
        child,
        childDelta,
        effectiveSearchPriority(child),
        minProbability,
        queue,
        fenMap,
        chain,
      );
      continue;
    }
    final target = _registeredCanonicalOf(child, fenMap);
    if (target != null) {
      addArrivalCumP(
        target,
        childDelta,
        minProbability,
        queue,
        fenMap: fenMap,
        active: chain,
      );
    } else if (!child.explored &&
        child.cumulativeProbability >= minProbability) {
      queue.add(child);
    }
  }
}

/// The canonical node [leaf] has been closed against, when the build has
/// registered it as a transposition leaf — null for every other leaf.
BuildTreeNode? _registeredCanonicalOf(BuildTreeNode leaf, FenMap? fenMap) {
  if (fenMap == null) return null;
  for (final t in fenMap.getTranspositions(leaf.fen)) {
    if (identical(t, leaf)) {
      final canonical = fenMap.getCanonical(leaf.fen);
      return canonical == null || identical(canonical, leaf) ? null : canonical;
    }
  }
  return null;
}
