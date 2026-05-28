/// Pre-indexed trap lookups for O(1) position and line queries.
///
/// Built once on trap file load, invalidated on regeneration.
library;

import 'dart:math' show max;

import '../models/trap_line_info.dart';

class TrapIndexService {
  final List<TrapLineInfo> _traps;

  late final Map<String, TrapLineInfo> _fenIndex;
  late final TrapRepertoireMetrics metrics;

  TrapIndexService(this._traps) {
    _buildFenIndex();
    _computeMetrics();
  }

  TrapLineInfo? trapAtFen(String fen) => _fenIndex[fen];

  List<TrapLineInfo> trapsInLine(List<String> lineMoves) {
    return _traps
        .where((t) =>
            t.movesSan.length <= lineMoves.length &&
            _isPrefix(t.movesSan, lineMoves))
        .toList()
      ..sort(
          (a, b) => a.movesSan.length.compareTo(b.movesSan.length));
  }

  TrapLineMetrics metricsForLine(List<String> lineMoves) {
    final traps = trapsInLine(lineMoves);
    if (traps.isEmpty) return TrapLineMetrics.empty;
    return TrapLineMetrics(
      count: traps.length,
      bestEvalDiff: traps.map((t) => t.evalDiffCp).reduce(max),
      totalReach: traps
          .map((t) => t.cumulativeProb)
          .reduce((a, b) => a + b),
      expectedTrapValue: traps
          .map(
              (t) => t.cumulativeProb * t.popularProb * t.evalDiffCp)
          .reduce((a, b) => a + b),
    );
  }

  void _buildFenIndex() {
    _fenIndex = {};
    for (final trap in _traps) {
      if (trap.fen != null) {
        _fenIndex.putIfAbsent(trap.fen!, () => trap);
      }
    }
  }

  void _computeMetrics() {
    if (_traps.isEmpty) {
      metrics = TrapRepertoireMetrics.empty;
      return;
    }
    metrics = TrapRepertoireMetrics(
      totalTraps: _traps.length,
      highQualityCount:
          _traps.where((t) => t.trickSurplus > 0.10).length,
      avgReach: _traps
              .map((t) => t.cumulativeProb)
              .reduce((a, b) => a + b) /
          _traps.length,
      avgEvalGain: _traps
              .map((t) => t.evalDiffCp.toDouble())
              .reduce((a, b) => a + b) /
          _traps.length,
      expectedTrapValue: _traps
          .map(
              (t) => t.cumulativeProb * t.popularProb * t.evalDiffCp)
          .reduce((a, b) => a + b),
    );
  }

  static bool _isPrefix(List<String> prefix, List<String> line) {
    for (int i = 0; i < prefix.length; i++) {
      if (prefix[i] != line[i]) return false;
    }
    return true;
  }
}

class TrapLineMetrics {
  final int count;
  final int bestEvalDiff;
  final double totalReach;
  final double expectedTrapValue;

  const TrapLineMetrics({
    required this.count,
    required this.bestEvalDiff,
    required this.totalReach,
    required this.expectedTrapValue,
  });

  static const empty = TrapLineMetrics(
    count: 0,
    bestEvalDiff: 0,
    totalReach: 0,
    expectedTrapValue: 0,
  );
}

class TrapRepertoireMetrics {
  final int totalTraps;
  final int highQualityCount;
  final double avgReach;
  final double avgEvalGain;
  final double expectedTrapValue;

  const TrapRepertoireMetrics({
    required this.totalTraps,
    required this.highQualityCount,
    required this.avgReach,
    required this.avgEvalGain,
    required this.expectedTrapValue,
  });

  static const empty = TrapRepertoireMetrics(
    totalTraps: 0,
    highQualityCount: 0,
    avgReach: 0,
    avgEvalGain: 0,
    expectedTrapValue: 0,
  );
}
