/// Per-subtree aggregates for the repertoire explorer: how many traps a line
/// holds, where the opponent struggles most and how natural our moves are.
library;

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

  bool _isTrapPosition(EvalTreeNodeSnapshot node) {
    if (snapshot.isOurTurnAt(node.id)) return false;
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
    double? minMyEase;
    final qualityValues = <double>[];

    for (final childId in node.childIds) {
      final childMetrics = _compute(childId);
      trapCount += childMetrics.subtreeTrapCount;
      minOpponentEase = _minOf(minOpponentEase, childMetrics.expectedEaseDeep);
      minMyEase = _minOf(minMyEase, childMetrics.bottleneckMyEase);
      if (childMetrics.linePlayability case final playability?) {
        qualityValues.add(playability);
      }
    }

    if (snapshot.isOurTurnAt(nodeId)) {
      if (node.myEase case final myEase?) {
        qualityValues.add(myEase);
        minMyEase = _minOf(minMyEase, myEase);
      }
    } else if (node.ease case final ease?) {
      minOpponentEase = _minOf(minOpponentEase, ease);
      // Opponent quality: how hard it is for them (1 - ease).
      // Low ease = opponent struggles = high quality for us.
      qualityValues.add(1.0 - ease);
    }

    final metrics = EvalTreeLineMetrics(
      subtreeTrapCount: trapCount,
      expectedEaseDeep: minOpponentEase,
      linePlayability: _geometricMean(qualityValues),
      bottleneckMyEase: minMyEase,
    );
    _byNodeId[nodeId] = metrics;
    return metrics;
  }

  static double? _minOf(double? current, double? candidate) {
    if (candidate == null) return current;
    return current == null ? candidate : math.min(current, candidate);
  }

  /// Geometric mean of [values] (each floored at 0.01 so one zero does not
  /// erase the rest), or null when there are none.
  static double? _geometricMean(List<double> values) {
    if (values.isEmpty) return null;
    final logSum = values
        .map((q) => math.log(q.clamp(0.01, 1.0)))
        .reduce((a, b) => a + b);
    return math.exp(logSum / values.length).clamp(0.0, 1.0);
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

/// Builds sorted candidate rows for the current position: repertoire moves
/// first, then — at our turn — the most natural move with the toughest line
/// below it, or — at theirs — the reply that is easiest for them (the one
/// they will find), and probability last.
List<EvalTreeCandidateRow> buildCandidateRows({
  required EvalTreeSnapshot snapshot,
  required EvalTreeLineMetricsCache metricsCache,
  required int currentNodeId,
}) {
  final children = snapshot.childrenOf(currentNodeId);
  if (children.isEmpty) return const [];

  final isOurTurn = snapshot.isOurTurnAt(currentNodeId);
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
      final myEaseCmp = (b.node.myEase ?? 0.5).compareTo(a.node.myEase ?? 0.5);
      if (myEaseCmp != 0) return myEaseCmp;
      final easeCmp = _compareKnownFirst(
        a.lineMetrics.expectedEaseDeep ?? a.node.ease,
        b.lineMetrics.expectedEaseDeep ?? b.node.ease,
        ascending: true,
      );
      if (easeCmp != 0) return easeCmp;
      final trapCmp = b.lineMetrics.subtreeTrapCount.compareTo(
        a.lineMetrics.subtreeTrapCount,
      );
      if (trapCmp != 0) return trapCmp;
    } else {
      final easeCmp = _compareKnownFirst(
        a.node.ease,
        b.node.ease,
        ascending: false,
      );
      if (easeCmp != 0) return easeCmp;
    }
    return b.node.moveProbability.compareTo(a.node.moveProbability);
  });

  return [
    for (final (i, row) in rows.indexed)
      EvalTreeCandidateRow(
        node: row.node,
        lineMetrics: row.lineMetrics,
        rank: i + 1,
      ),
  ];
}

/// Orders two optional values with the known one first; two known values
/// compare [ascending] or descending, two unknown ones are equal.
int _compareKnownFirst(double? a, double? b, {required bool ascending}) {
  if (a != null && b != null) {
    return ascending ? a.compareTo(b) : b.compareTo(a);
  }
  if (a != null) return -1;
  if (b != null) return 1;
  return 0;
}
