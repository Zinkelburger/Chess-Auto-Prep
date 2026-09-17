/// Turns a [BuildTree] into the immutable [EvalTreeSnapshot] the viewer
/// reads, deriving what the tree may not have stored (subtree size and
/// depth) in one bottom-up pass.
library;

import '../../../chess_core/generation/build_tree_node.dart';
import '../../../utils/san_token_utils.dart';
import '../models/eval_tree_snapshot.dart';

/// Subtree size and depth as derived for one node.
typedef _SubtreeMetrics = ({int subtreeSize, int subtreePly});

class EvalTreeSnapshotAdapter {
  static EvalTreeSnapshot fromBuildTree(
    BuildTree tree, {
    required bool playAsWhite,
  }) {
    final nodesById = <int, EvalTreeNodeSnapshot>{};
    _visitNode(tree.root, playAsWhite, nodesById);
    return EvalTreeSnapshot(
      rootNodeId: tree.root.nodeId,
      playAsWhite: playAsWhite,
      startMovesSan: cleanSanTokens(tree.startMoves),
      configSnapshot: tree.configSnapshot,
      nodesById: nodesById,
    );
  }

  static _SubtreeMetrics _visitNode(
    BuildTreeNode node,
    bool playAsWhite,
    Map<int, EvalTreeNodeSnapshot> nodesById,
  ) {
    var derivedSubtreeSize = 1;
    var derivedSubtreePly = 0;
    for (final child in node.children) {
      final childMetrics = _visitNode(child, playAsWhite, nodesById);
      derivedSubtreeSize += childMetrics.subtreeSize;
      derivedSubtreePly = _max(derivedSubtreePly, childMetrics.subtreePly + 1);
    }

    // The tree's own metadata wins when it was computed; a tree that never
    // had computeMetadata run gets the values derived here.
    final metrics = (
      subtreeSize: node.subtreeSize > 0 ? node.subtreeSize : derivedSubtreeSize,
      subtreePly: node.subtreePly > 0 || node.children.isEmpty
          ? node.subtreePly
          : derivedSubtreePly,
    );

    nodesById[node.nodeId] = EvalTreeNodeSnapshot(
      id: node.nodeId,
      parentId: node.parent?.nodeId,
      childIds: List.unmodifiable(node.children.map((child) => child.nodeId)),
      fen: node.fen,
      moveSan: node.moveSan,
      moveUci: node.moveUci,
      sideToMoveIsWhite: node.isWhiteToMove,
      evalForUsCp: node.hasEngineEval ? node.evalForUs(playAsWhite) : null,
      moveProbability: node.moveProbability,
      cumulativeProbability: node.cumulativeProbability,
      isRepertoireMove: node.isRepertoireMove,
      repertoireScore: _repertoireScore(node),
      ease: node.ease,
      expectimaxValue: node.hasExpectimax ? node.expectimaxValue : null,
      localCpl: _localCpl(node),
      trapScore: node.trapScore >= 0.0 ? node.trapScore : null,
      myEase: node.myEase >= 0.0 ? node.myEase : null,
      subtreeSize: metrics.subtreeSize,
      subtreePly: metrics.subtreePly,
      pruneKind: _pruneKind(node.pruneReason),
      pruneEvalCp: node.pruneEvalCp,
      totalGames: node.totalGames,
    );
    return metrics;
  }

  /// A node without expectimax only has a meaningful loss when one was
  /// recorded; zero there means "unknown", not "best".
  static double? _localCpl(BuildTreeNode node) => node.hasExpectimax
      ? node.localCpl
      : (node.localCpl > 0 ? node.localCpl : null);

  /// Older trees stored no repertoire score; the expectimax value of a
  /// selected move stands in for it.
  static double _repertoireScore(BuildTreeNode node) =>
      node.repertoireScore != 0.0
      ? node.repertoireScore
      : (node.isRepertoireMove ? node.expectimaxValue : 0.0);

  static EvalTreePruneKind _pruneKind(PruneReason reason) => switch (reason) {
    PruneReason.none => EvalTreePruneKind.none,
    PruneReason.evalTooHigh => EvalTreePruneKind.evalTooHigh,
    PruneReason.evalTooLow => EvalTreePruneKind.evalTooLow,
  };

  static int _max(int a, int b) => a > b ? a : b;
}
