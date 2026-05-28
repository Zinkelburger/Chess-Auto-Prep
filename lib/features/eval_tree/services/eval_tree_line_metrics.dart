import 'dart:math' as math;

import '../models/eval_tree_snapshot.dart';

/// Minimum trap score to count a position as trappy (matches [TrapExtractor]).
const double kEvalTreeTrapThreshold = 0.05;

/// Aggregated metrics for a candidate line / subtree, computed at load time
/// from an [EvalTreeSnapshot].
class EvalTreeLineMetrics {
  /// Number of trappy opponent-move positions in this subtree.
  final int subtreeTrapCount;

  /// Minimum ease at opponent-to-move nodes in the subtree.
  ///
  /// Lower values mean the opponent struggles somewhere deeper in the line.
  /// Null when no ease data exists in the subtree.
  final double? expectedEaseDeep;

  /// How natural our moves are in this subtree (geometric mean of myEase).
  /// Null when no myEase data exists.
  final double? linePlayability;

  /// Minimum myEase value among our-move children in this subtree.
  /// Null when no myEase data exists.
  final double? bottleneckMyEase;

  const EvalTreeLineMetrics({
    required this.subtreeTrapCount,
    required this.expectedEaseDeep,
    this.linePlayability,
    this.bottleneckMyEase,
  });

  static const empty = EvalTreeLineMetrics(
    subtreeTrapCount: 0,
    expectedEaseDeep: null,
  );
}

/// Pre-computes per-node subtree metrics for fast explorer lookups.
///
/// Computed at snapshot load time from [EvalTreeNodeSnapshot.trapScore] and
/// [EvalTreeNodeSnapshot.ease] already stored on each node. To avoid this
/// post-load walk on very large trees, these aggregates could be persisted
/// during tree build (see [BuildTree.computeMetadata]) as `subtree_trap_count`
/// and `expected_ease_deep` fields on [BuildTreeNode].
class EvalTreeLineMetricsCache {
  final EvalTreeSnapshot snapshot;
  final Map<int, EvalTreeLineMetrics> _byNodeId;

  EvalTreeLineMetricsCache._(this.snapshot, this._byNodeId);

  factory EvalTreeLineMetricsCache.fromSnapshot(EvalTreeSnapshot snapshot) {
    final cache = EvalTreeLineMetricsCache._(snapshot, {});
    cache._compute(snapshot.rootNodeId);
    return cache;
  }

  EvalTreeLineMetrics metricsFor(int nodeId) =>
      _byNodeId[nodeId] ?? EvalTreeLineMetrics.empty;

  bool _isOpponentTurn(EvalTreeNodeSnapshot node) =>
      node.sideToMoveIsWhite != snapshot.playAsWhite;

  bool _isTrapPosition(EvalTreeNodeSnapshot node) {
    if (!_isOpponentTurn(node)) return false;
    if (node.childIds.length < 2) return false;
    final trap = node.trapScore;
    return trap != null && trap >= kEvalTreeTrapThreshold;
  }

  EvalTreeLineMetrics _compute(int nodeId) {
    final existing = _byNodeId[nodeId];
    if (existing != null) return existing;

    final node = snapshot.node(nodeId);
    var trapCount = _isTrapPosition(node) ? 1 : 0;
    double? minOpponentEase;

    final qualityValues = <double>[];
    double? minMyEase;

    for (final childId in node.childIds) {
      final childMetrics = _compute(childId);
      trapCount += childMetrics.subtreeTrapCount;

      final childEase = childMetrics.expectedEaseDeep;
      if (childEase != null) {
        minOpponentEase = minOpponentEase == null
            ? childEase
            : (childEase < minOpponentEase ? childEase : minOpponentEase);
      }

      if (childMetrics.linePlayability != null) {
        qualityValues.add(childMetrics.linePlayability!);
      }
      final childBottleneck = childMetrics.bottleneckMyEase;
      if (childBottleneck != null) {
        minMyEase = minMyEase == null
            ? childBottleneck
            : (childBottleneck < minMyEase ? childBottleneck : minMyEase);
      }
    }

    if (_isOpponentTurn(node)) {
      if (node.ease != null) {
        final ease = node.ease!;
        minOpponentEase = minOpponentEase == null
            ? ease
            : (ease < minOpponentEase ? ease : minOpponentEase);
        // Opponent quality: how hard it is for them (1 - ease).
        // Low ease = opponent struggles = high quality for us.
        qualityValues.add(1.0 - ease);
      }
    } else {
      if (node.myEase != null) {
        qualityValues.add(node.myEase!);
        minMyEase = minMyEase == null
            ? node.myEase!
            : (node.myEase! < minMyEase ? node.myEase! : minMyEase);
      }
    }

    double? playability;
    if (qualityValues.isNotEmpty) {
      final logSum = qualityValues
          .map((q) => math.log(q.clamp(0.01, 1.0)))
          .reduce((a, b) => a + b);
      playability = math.exp(logSum / qualityValues.length).clamp(0.0, 1.0);
    }

    final metrics = EvalTreeLineMetrics(
      subtreeTrapCount: trapCount,
      expectedEaseDeep: minOpponentEase,
      linePlayability: playability,
      bottleneckMyEase: minMyEase,
    );
    _byNodeId[nodeId] = metrics;
    return metrics;
  }
}

/// Candidate move row data for the repertoire explorer table.
class EvalTreeCandidateRow {
  final EvalTreeNodeSnapshot node;
  final EvalTreeLineMetrics lineMetrics;
  final int rank;

  const EvalTreeCandidateRow({
    required this.node,
    required this.lineMetrics,
    required this.rank,
  });
}

/// Builds sorted candidate rows for the current position.
List<EvalTreeCandidateRow> buildCandidateRows({
  required EvalTreeSnapshot snapshot,
  required EvalTreeLineMetricsCache metricsCache,
  required int currentNodeId,
}) {
  final children = snapshot.childrenOf(currentNodeId);
  if (children.isEmpty) return const [];

  final current = snapshot.node(currentNodeId);
  final isOurTurn = current.sideToMoveIsWhite == snapshot.playAsWhite;

  final rows = [
    for (final child in children)
      EvalTreeCandidateRow(
        node: child,
        lineMetrics: metricsCache.metricsFor(child.id),
        rank: 0,
      ),
  ];

  rows.sort((a, b) {
    if (a.node.isRepertoireMove != b.node.isRepertoireMove) {
      return a.node.isRepertoireMove ? -1 : 1;
    }

    if (isOurTurn) {
      final aMyEase = a.node.myEase ?? 0.5;
      final bMyEase = b.node.myEase ?? 0.5;
      final myEaseCmp = bMyEase.compareTo(aMyEase);
      if (myEaseCmp != 0) return myEaseCmp;

      final aEase = a.lineMetrics.expectedEaseDeep ?? a.node.ease;
      final bEase = b.lineMetrics.expectedEaseDeep ?? b.node.ease;
      if (aEase != null && bEase != null) {
        final cmp = aEase.compareTo(bEase);
        if (cmp != 0) return cmp;
      } else if (aEase != null) {
        return -1;
      } else if (bEase != null) {
        return 1;
      }

      final trapCmp =
          b.lineMetrics.subtreeTrapCount.compareTo(a.lineMetrics.subtreeTrapCount);
      if (trapCmp != 0) return trapCmp;
    } else {
      final aEase = a.node.ease;
      final bEase = b.node.ease;
      if (aEase != null && bEase != null) {
        final cmp = bEase.compareTo(aEase);
        if (cmp != 0) return cmp;
      } else if (aEase != null) {
        return -1;
      } else if (bEase != null) {
        return 1;
      }
    }

    return b.node.moveProbability.compareTo(a.node.moveProbability);
  });

  return [
    for (var i = 0; i < rows.length; i++)
      EvalTreeCandidateRow(
        node: rows[i].node,
        lineMetrics: rows[i].lineMetrics,
        rank: i + 1,
      ),
  ];
}
