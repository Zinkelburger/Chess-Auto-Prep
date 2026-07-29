/// Subtree surgery for reusing already-built tree fragments.
///
/// When the analyzed position moves to a node that already exists inside a
/// previously built [BuildTree] (on-the-fly session tree, cached result, or
/// the main generated tree), the subtree under that node can seed the next
/// build instead of starting from scratch.  [BuildTreeNode.ply] is final and
/// [BuildTreeNode.cumulativeProbability] is path-dependent, so reuse means
/// cloning with rebased bookkeeping, not re-parenting.
library;

import '../../models/build_tree_node.dart';

/// Clone the subtree under [source] as a standalone [BuildTree] whose root
/// is [source]'s position at ply 0.
///
/// Rebased per node: `ply` (root offset subtracted via fresh depth count),
/// `cumulativeProbability` (recomputed as the product of opponent-move
/// probabilities from the new root), `nodeId` (fresh sequence from 1), and
/// `searchPriority` (reset to unset — the resume path derives it from the
/// recomputed reach probability).  Preserved per node: evals, Lichess stats,
/// `explored`/prune state, and phase-2 display values so previously computed
/// lines can render before the next build pass refines them.
///
/// [playAsWhite] decides which edges count as opponent moves for the
/// cumulative-probability product.
BuildTree extractRebasedSubtree(
  BuildTreeNode source, {
  required bool playAsWhite,
}) {
  var nextNodeId = 1;
  var nodeCount = 0;

  BuildTreeNode clone(
    BuildTreeNode old, {
    required BuildTreeNode? parent,
    required int ply,
    required double parentCumP,
  }) {
    // The move into a node is the opponent's when the node's side to move
    // is ours again; only those edges shrink reach probability.
    final moveWasOpponents = parent != null && old.isWhiteToMove == playAsWhite;
    final cumP = moveWasOpponents
        ? parentCumP * old.moveProbability
        : parentCumP;

    final node = BuildTreeNode(
      fen: old.fen,
      // The new root is a position, not a move — match a fresh build root.
      moveSan: parent == null ? '' : old.moveSan,
      moveUci: parent == null ? '' : old.moveUci,
      ply: ply,
      isWhiteToMove: old.isWhiteToMove,
      nodeId: nextNodeId++,
      parent: parent,
      moveProbability: parent == null ? 1.0 : old.moveProbability,
      cumulativeProbability: cumP,
    );
    node
      ..engineEvalCp = old.engineEvalCp
      ..explored = old.explored
      ..pruneReason = old.pruneReason
      ..pruneEvalCp = old.pruneEvalCp
      ..openingName = old.openingName
      ..openingEco = old.openingEco
      ..maiaFrequency = old.maiaFrequency
      ..pvContinuationMove = old.pvContinuationMove
      ..engineInjected = old.engineInjected
      ..extEvalMode = old.extEvalMode
      ..isRepertoireMove = old.isRepertoireMove
      ..ease = old.ease
      ..localCpl = old.localCpl
      ..expectimaxValue = old.expectimaxValue
      ..cplValue = old.cplValue
      ..hasExpectimax = old.hasExpectimax
      ..opponentEase = old.opponentEase
      ..trapScore = old.trapScore
      ..myEase = old.myEase;
    node.setLichessStats(old.whiteWins, old.blackWins, old.draws);
    nodeCount++;

    for (final child in old.children) {
      node.children.add(
        clone(child, parent: node, ply: ply + 1, parentCumP: cumP),
      );
    }
    return node;
  }

  final root = clone(source, parent: null, ply: 0, parentCumP: 1.0);
  final tree = BuildTree(root: root, totalNodes: nodeCount);
  tree.computeMetadata();
  return tree;
}

/// Reset `explored` on childless explored leaves shallower than [belowPly]
/// that carry no explicit prune reason, so a resumed build expands them.
///
/// Such leaves are depth-capped or transposition leaves from the previous
/// pass — not decisions.  Explicitly pruned leaves (eval window) stay closed.
/// Returns the number of leaves reopened.
int reopenExpansionLeaves(BuildTreeNode node, {required int belowPly}) {
  if (node.children.isEmpty) {
    if (node.explored &&
        node.pruneReason == PruneReason.none &&
        node.ply < belowPly) {
      node.explored = false;
      return 1;
    }
    return 0;
  }
  var reopened = 0;
  for (final child in node.children) {
    reopened += reopenExpansionLeaves(child, belowPly: belowPly);
  }
  return reopened;
}
