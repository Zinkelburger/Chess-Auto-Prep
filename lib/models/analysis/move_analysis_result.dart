/// Public result types emitted by [AnalysisService].
library;

import '../../utils/eval_constants.dart';

/// Per-move analysis result combining eval data.
class MoveAnalysisResult {
  final int? scoreCp; // White perspective
  final int? scoreMate; // White perspective
  final List<String> pv; // Full PV (move + continuation)
  final int depth;

  MoveAnalysisResult({
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.depth = 0,
  });

  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: scoreCp, scoreMate: scoreMate);

  bool get hasEval => scoreCp != null || scoreMate != null;
}

/// Structured pool status for UI consumption.
class PoolStatus {
  final String phase; // 'idle', 'discovering', 'evaluating', 'complete'
  final List<String> evaluatingUcis;
  final int totalMoves;
  final int completedMoves;
  final int activeWorkers;
  final int hashPerWorkerMb;
  // Discovery progress
  final int discoveryDepth;
  final int discoveryNodes;
  final int discoveryNps;

  const PoolStatus({
    this.phase = 'idle',
    this.evaluatingUcis = const [],
    this.totalMoves = 0,
    this.completedMoves = 0,
    this.activeWorkers = 0,
    this.hashPerWorkerMb = 0,
    this.discoveryDepth = 0,
    this.discoveryNodes = 0,
    this.discoveryNps = 0,
  });

  bool get isIdle => phase == 'idle';
  bool get isDiscovering => phase == 'discovering';
  bool get isEvaluating => phase == 'evaluating';
  bool get isComplete => phase == 'complete';
}
