/// Public result types emitted by [AnalysisService].
library;

import '../../utils/eval_constants.dart';

/// Per-move analysis result combining eval data.
class MoveAnalysisResult {
  final int? scoreCp; // White perspective
  final int? scoreMate; // White perspective
  final List<String> pv; // Full PV (move + continuation)
  final int depth;

  const MoveAnalysisResult({
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.depth = 0,
  });

  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: scoreCp, scoreMate: scoreMate);

  bool get hasEval => scoreCp != null || scoreMate != null;
}

/// Where the analysis pool is in its two-phase run.
enum PoolPhase { idle, discovering, evaluating, complete }

/// Structured pool status for UI consumption.
class PoolStatus {
  final PoolPhase phase;
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
    this.phase = PoolPhase.idle,
    this.evaluatingUcis = const [],
    this.totalMoves = 0,
    this.completedMoves = 0,
    this.activeWorkers = 0,
    this.hashPerWorkerMb = 0,
    this.discoveryDepth = 0,
    this.discoveryNodes = 0,
    this.discoveryNps = 0,
  });

  bool get isIdle => phase == PoolPhase.idle;
  bool get isDiscovering => phase == PoolPhase.discovering;
  bool get isEvaluating => phase == PoolPhase.evaluating;
  bool get isComplete => phase == PoolPhase.complete;
}
