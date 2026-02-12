/// Pure resource-budgeting logic for the Stockfish worker pool.
///
/// All methods are static and take system parameters as inputs so they
/// can be unit-tested without OS access or running processes.
///
/// The pool calls these with live data from [getSystemLoad]; tests call
/// them with synthetic scenarios.
library;

/// Per-Stockfish-process overhead in MB (binary + stack + misc).
const int kProcessOverheadMb = 40;

/// Minimum Stockfish hash table size in MB.
const int kMinHashMb = 16;

/// Input snapshot of the system state at a point in time.
class SystemSnapshot {
  /// Total physical RAM in MB.
  final int totalRamMb;

  /// Currently free / reclaimable RAM in MB.
  final int freeRamMb;

  /// Number of logical CPU cores.
  final int logicalCores;

  const SystemSnapshot({
    required this.totalRamMb,
    required this.freeRamMb,
    required this.logicalCores,
  });

  /// RAM currently used by the OS + other processes.
  int get usedRamMb => totalRamMb - freeRamMb;
}

/// Current state of the worker pool (how many workers, how much hash each).
class PoolState {
  final int workerCount;
  final int hashPerWorkerMb;

  const PoolState({this.workerCount = 0, this.hashPerWorkerMb = 0});

  /// Total RAM our workers are currently using (hash + process overhead).
  int get ownAllocationMb =>
      workerCount * (hashPerWorkerMb + kProcessOverheadMb);
}

/// Computed resource budget: how many workers to target and how much
/// hash each should get.
class ResourceBudget {
  /// Per-worker hash in MB.
  final int hashPerWorkerMb;

  /// How many workers RAM can support right now.
  final int workerCapacity;

  /// The effective headroom used for the computation.
  final int effectiveHeadroomMb;

  /// Total RAM that [workerCapacity] workers would consume.
  int get totalAllocationMb =>
      workerCapacity * (hashPerWorkerMb + kProcessOverheadMb);

  const ResourceBudget({
    required this.hashPerWorkerMb,
    required this.workerCapacity,
    required this.effectiveHeadroomMb,
  });
}

/// Pure resource budget computations — no OS calls, fully testable.
class PoolResourceBudget {
  const PoolResourceBudget._();

  /// Effective RAM headroom in MB.
  ///
  /// The OS reports our own workers' hash tables as "used" RAM, but that
  /// memory is ours to reclaim / redistribute.  So:
  ///
  ///     effective = (ceiling% × totalRam − usedRam) + ownAllocation
  ///
  /// This prevents the pool from starving itself on re-evaluation.
  static int effectiveHeadroomMb({
    required SystemSnapshot system,
    required double maxLoadPercent,
    required PoolState pool,
  }) {
    final ceilingMb = (system.totalRamMb * maxLoadPercent / 100.0).round();
    final rawHeadroom = (ceilingMb - system.usedRamMb).clamp(0, system.totalRamMb);
    return rawHeadroom + pool.ownAllocationMb;
  }

  /// Compute per-worker hash assuming [maxWorkers] will all run.
  ///
  /// Divides effective headroom evenly minus per-process overhead.
  /// Result is clamped to `[kMinHashMb, hashCeilingMb]`.
  static int hashForMaxWorkers({
    required int effectiveHeadroomMb,
    required int maxWorkers,
    required int hashCeilingMb,
  }) {
    if (maxWorkers <= 0) return hashCeilingMb.clamp(kMinHashMb, hashCeilingMb);

    final forHash = effectiveHeadroomMb - maxWorkers * kProcessOverheadMb;
    if (forHash <= 0) return kMinHashMb;

    final perWorker = forHash ~/ maxWorkers;
    return perWorker.clamp(kMinHashMb, hashCeilingMb);
  }

  /// How many workers can RAM support at [hashPerWorkerMb]?
  ///
  /// Always returns at least 1 (minimum viable pool) and at most [maxWorkers].
  static int workerCapacity({
    required int effectiveHeadroomMb,
    required int maxWorkers,
    required int hashPerWorkerMb,
  }) {
    final costPerInstance = hashPerWorkerMb + kProcessOverheadMb;
    if (costPerInstance <= 0) return maxWorkers;
    return (effectiveHeadroomMb ~/ costPerInstance).clamp(1, maxWorkers);
  }

  /// Compute the full budget in one call.
  static ResourceBudget compute({
    required SystemSnapshot system,
    required double maxLoadPercent,
    required int maxWorkers,
    required int hashCeilingMb,
    PoolState pool = const PoolState(),
  }) {
    final headroom = effectiveHeadroomMb(
      system: system,
      maxLoadPercent: maxLoadPercent,
      pool: pool,
    );

    final hash = hashForMaxWorkers(
      effectiveHeadroomMb: headroom,
      maxWorkers: maxWorkers,
      hashCeilingMb: hashCeilingMb,
    );

    final capacity = workerCapacity(
      effectiveHeadroomMb: headroom,
      maxWorkers: maxWorkers,
      hashPerWorkerMb: hash,
    );

    return ResourceBudget(
      hashPerWorkerMb: hash,
      workerCapacity: capacity,
      effectiveHeadroomMb: headroom,
    );
  }

  // ── Invariant checks (for tests) ────────────────────────────────────

  /// Verify that [n] workers at [hashMb] each won't push total system
  /// usage above [maxLoadPercent] of [totalRamMb].
  ///
  /// [otherUsedMb] is RAM used by everything *except* our pool.
  static bool isWithinCeiling({
    required int totalRamMb,
    required double maxLoadPercent,
    required int otherUsedMb,
    required int workerCount,
    required int hashPerWorkerMb,
  }) {
    final ceilingMb = (totalRamMb * maxLoadPercent / 100.0).round();
    final totalUsed = otherUsedMb +
        workerCount * (hashPerWorkerMb + kProcessOverheadMb);
    return totalUsed <= ceilingMb;
  }
}
