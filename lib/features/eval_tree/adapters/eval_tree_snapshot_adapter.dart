import '../../../models/build_tree_node.dart';
import '../models/eval_tree_snapshot.dart';

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
      startMovesSan: _parseStartMoves(tree.startMoves),
      configSnapshot: tree.configSnapshot,
      nodesById: nodesById,
    );
  }

  static _DerivedNodeMetrics _visitNode(
    BuildTreeNode node,
    bool playAsWhite,
    Map<int, EvalTreeNodeSnapshot> nodesById,
  ) {
    var derivedSubtreeSize = 1;
    var derivedSubtreePly = 0;

    for (final child in node.children) {
      final childMetrics = _visitNode(child, playAsWhite, nodesById);
      derivedSubtreeSize += childMetrics.subtreeSize;
      final candidatePly = childMetrics.subtreePly + 1;
      if (candidatePly > derivedSubtreePly) {
        derivedSubtreePly = candidatePly;
      }
    }

    final localCpl = node.hasExpectimax
        ? node.localCpl
        : (node.localCpl > 0 ? node.localCpl : null);
    final repertoireScore = node.repertoireScore != 0.0
        ? node.repertoireScore
        : (node.isRepertoireMove ? node.expectimaxValue : 0.0);

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
      repertoireScore: repertoireScore,
      ease: node.ease,
      expectimaxValue: node.hasExpectimax ? node.expectimaxValue : null,
      localCpl: localCpl,
      trapScore: node.trapScore >= 0.0 ? node.trapScore : null,
      subtreeSize: node.subtreeSize > 0 ? node.subtreeSize : derivedSubtreeSize,
      subtreePly: node.subtreePly > 0 || node.children.isEmpty
          ? node.subtreePly
          : derivedSubtreePly,
      pruneKind: _mapPruneKind(node.pruneReason),
      pruneEvalCp: node.pruneEvalCp,
      totalGames: node.totalGames,
    );

    return _DerivedNodeMetrics(
      subtreeSize: node.subtreeSize > 0 ? node.subtreeSize : derivedSubtreeSize,
      subtreePly: node.subtreePly > 0 || node.children.isEmpty
          ? node.subtreePly
          : derivedSubtreePly,
    );
  }

  static EvalTreePruneKind _mapPruneKind(PruneReason reason) {
    switch (reason) {
      case PruneReason.none:
        return EvalTreePruneKind.none;
      case PruneReason.evalTooHigh:
        return EvalTreePruneKind.evalTooHigh;
      case PruneReason.evalTooLow:
        return EvalTreePruneKind.evalTooLow;
    }
  }

  static List<String> _parseStartMoves(String startMoves) {
    final trimmed = startMoves.trim();
    if (trimmed.isEmpty) return const [];
    return trimmed
        .split(RegExp(r'\s+'))
        .where((token) =>
            token.isNotEmpty && !RegExp(r'^\d+\.(?:\.\.)?$').hasMatch(token))
        .toList(growable: false);
  }
}

class _DerivedNodeMetrics {
  final int subtreeSize;
  final int subtreePly;

  const _DerivedNodeMetrics({
    required this.subtreeSize,
    required this.subtreePly,
  });
}
