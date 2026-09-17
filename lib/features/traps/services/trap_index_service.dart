/// Pre-indexed trap lookups: [trapAtFen] is O(1); [trapsInLine] is O(n).
///
/// Built once on trap file load, invalidated on regeneration.
library;

import 'dart:math' show max;

import '../../../chess_core/generation/trap_line_info.dart';
import '../../../chess_core/position/eval_canonicalize.dart';

class TrapIndexService {
  TrapIndexService(List<TrapLineInfo> traps)
    : _traps = traps,
      _fenIndex = _buildFenIndex(traps),
      metrics = _computeMetrics(traps);

  final List<TrapLineInfo> _traps;
  final Map<String, TrapLineInfo> _fenIndex;
  final TrapRepertoireMetrics metrics;

  /// All traps in load order (unmodifiable).
  List<TrapLineInfo> get allTraps => List.unmodifiable(_traps);

  /// Look up a trap by position. Keyed on the canonical 4-field FEN so a
  /// transposed arrival (same position, different move counters) resolves to
  /// the same trap — matching how [TrapExtractor] dedups.
  TrapLineInfo? trapAtFen(String fen) => _fenIndex[canonicalizeFen4(fen)];

  List<TrapLineInfo> trapsInLine(List<String> lineMoves) {
    return _traps
        .where(
          (t) =>
              t.movesSan.length <= lineMoves.length &&
              _isPrefix(t.movesSan, lineMoves),
        )
        .toList()
      ..sort((a, b) => a.movesSan.length.compareTo(b.movesSan.length));
  }

  TrapLineMetrics metricsForLine(List<String> lineMoves) {
    final traps = trapsInLine(lineMoves);
    if (traps.isEmpty) return TrapLineMetrics.empty;
    return TrapLineMetrics(
      count: traps.length,
      bestEvalDiff: traps.map((t) => t.evalDiffCp).reduce(max),
      totalReach: traps.map((t) => t.cumulativeProb).reduce((a, b) => a + b),
      expectedTrapValue: traps
          .map((t) => t.cumulativeProb * t.popularProb * t.evalDiffCp)
          .reduce((a, b) => a + b),
    );
  }

  static Map<String, TrapLineInfo> _buildFenIndex(List<TrapLineInfo> traps) {
    final index = <String, TrapLineInfo>{};
    for (final trap in traps) {
      final fen = trap.fen;
      if (fen != null) index.putIfAbsent(canonicalizeFen4(fen), () => trap);
    }
    return index;
  }

  static TrapRepertoireMetrics _computeMetrics(List<TrapLineInfo> traps) {
    if (traps.isEmpty) return TrapRepertoireMetrics.empty;
    return TrapRepertoireMetrics(
      totalTraps: traps.length,
      highQualityCount: traps.where((t) => t.trickSurplus > 0.10).length,
      avgReach:
          traps.map((t) => t.cumulativeProb).reduce((a, b) => a + b) /
          traps.length,
      avgEvalGain:
          traps.map((t) => t.evalDiffCp.toDouble()).reduce((a, b) => a + b) /
          traps.length,
      expectedTrapValue: traps
          .map((t) => t.cumulativeProb * t.popularProb * t.evalDiffCp)
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
