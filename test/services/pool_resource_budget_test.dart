import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/pool_resource_budget.dart';

void main() {
  // ════════════════════════════════════════════════════════════════════
  // Helper: common system configurations
  // ════════════════════════════════════════════════════════════════════

  // 32 GB, 8 cores, idle desktop (30% RAM used)
  const desktop32gb = SystemSnapshot(
    totalRamMb: 32768,
    freeRamMb: 22938, // ~30% used
    logicalCores: 8,
  );

  // 16 GB, 4 cores, moderate load (50% RAM used)
  const laptop16gb = SystemSnapshot(
    totalRamMb: 16384,
    freeRamMb: 8192, // 50% used
    logicalCores: 4,
  );

  // 8 GB, 2 cores, heavy load (75% RAM used)
  const lowEnd8gb = SystemSnapshot(
    totalRamMb: 8192,
    freeRamMb: 2048, // 75% used
    logicalCores: 2,
  );

  // 4 GB, 2 cores, nearly full (90% used)
  const tinyBox4gb = SystemSnapshot(
    totalRamMb: 4096,
    freeRamMb: 410, // 90% used
    logicalCores: 2,
  );

  // ════════════════════════════════════════════════════════════════════
  // effectiveHeadroomMb
  // ════════════════════════════════════════════════════════════════════

  group('effectiveHeadroomMb', () {
    test('fresh pool (no workers) — headroom is raw ceiling minus used', () {
      final headroom = PoolResourceBudget.effectiveHeadroomMb(
        system: desktop32gb,
        maxLoadPercent: 90.0,
        pool: const PoolState(),
      );
      // ceiling = 32768 * 0.9 = 29491
      // used = 32768 - 22938 = 9830
      // headroom = 29491 - 9830 = 19661
      expect(headroom, 19661);
    });

    test('own workers allocation is added back to headroom', () {
      const pool = PoolState(workerCount: 7, hashPerWorkerMb: 2000);
      final headroom = PoolResourceBudget.effectiveHeadroomMb(
        system: desktop32gb,
        maxLoadPercent: 90.0,
        pool: pool,
      );
      // raw headroom = 19661 (from above)
      // own = 7 * (2000 + 40) = 14280
      // effective = 19661 + 14280 = 33941
      expect(headroom, 19661 + 14280);
    });

    test('headroom never goes below own allocation (own memory always available)', () {
      // System nearly full, but our workers ARE the usage
      const system = SystemSnapshot(
        totalRamMb: 32768,
        freeRamMb: 500, // almost no free RAM
        logicalCores: 8,
      );
      const pool = PoolState(workerCount: 7, hashPerWorkerMb: 2000);
      final headroom = PoolResourceBudget.effectiveHeadroomMb(
        system: system,
        maxLoadPercent: 90.0,
        pool: pool,
      );
      // ceiling = 29491, used = 32268, raw = max(0, 29491 - 32268) = 0
      // own = 14280, effective = 14280
      expect(headroom, greaterThanOrEqualTo(pool.ownAllocationMb));
    });

    test('100% load ceiling uses full RAM', () {
      final headroom = PoolResourceBudget.effectiveHeadroomMb(
        system: desktop32gb,
        maxLoadPercent: 100.0,
        pool: const PoolState(),
      );
      // ceiling = 32768, used = 9830, headroom = 22938
      expect(headroom, desktop32gb.freeRamMb);
    });

    test('50% load ceiling cuts available space', () {
      final headroom = PoolResourceBudget.effectiveHeadroomMb(
        system: desktop32gb,
        maxLoadPercent: 50.0,
        pool: const PoolState(),
      );
      // ceiling = 16384, used = 9830 → headroom = 6554
      expect(headroom, 6554);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // hashForMaxWorkers
  // ════════════════════════════════════════════════════════════════════

  group('hashForMaxWorkers', () {
    test('divides headroom evenly minus overhead', () {
      final hash = PoolResourceBudget.hashForMaxWorkers(
        effectiveHeadroomMb: 20000,
        maxWorkers: 7,
        hashCeilingMb: 5000,
      );
      // forHash = 20000 - 7 * 40 = 19720
      // per worker = 19720 / 7 = 2817
      // clamped to [16, 5000] → 2817
      expect(hash, 2817);
    });

    test('never below kMinHashMb', () {
      final hash = PoolResourceBudget.hashForMaxWorkers(
        effectiveHeadroomMb: 100, // barely any headroom
        maxWorkers: 7,
        hashCeilingMb: 5000,
      );
      expect(hash, kMinHashMb);
    });

    test('respects hashCeilingMb cap', () {
      final hash = PoolResourceBudget.hashForMaxWorkers(
        effectiveHeadroomMb: 100000, // tons of headroom
        maxWorkers: 2,
        hashCeilingMb: 1024,
      );
      // forHash = 100000 - 80 = 99920, per worker = 49960
      // clamped to 1024
      expect(hash, 1024);
    });

    test('zero or negative headroom returns kMinHashMb', () {
      final hash = PoolResourceBudget.hashForMaxWorkers(
        effectiveHeadroomMb: 0,
        maxWorkers: 4,
        hashCeilingMb: 2048,
      );
      expect(hash, kMinHashMb);
    });

    test('headroom exactly covers overhead returns kMinHashMb', () {
      // headroom = 7 * 40 = 280, forHash = 0
      final hash = PoolResourceBudget.hashForMaxWorkers(
        effectiveHeadroomMb: 280,
        maxWorkers: 7,
        hashCeilingMb: 2048,
      );
      expect(hash, kMinHashMb);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // workerCapacity
  // ════════════════════════════════════════════════════════════════════

  group('workerCapacity', () {
    test('divides headroom by cost per instance', () {
      final cap = PoolResourceBudget.workerCapacity(
        effectiveHeadroomMb: 20000,
        maxWorkers: 7,
        hashPerWorkerMb: 2000,
      );
      // cost = 2040, capacity = 20000 / 2040 = 9, clamped to 7
      expect(cap, 7);
    });

    test('limited by headroom when tight', () {
      final cap = PoolResourceBudget.workerCapacity(
        effectiveHeadroomMb: 5000,
        maxWorkers: 7,
        hashPerWorkerMb: 2000,
      );
      // cost = 2040, capacity = 5000 / 2040 = 2
      expect(cap, 2);
    });

    test('always returns at least 1', () {
      final cap = PoolResourceBudget.workerCapacity(
        effectiveHeadroomMb: 10, // almost nothing
        maxWorkers: 7,
        hashPerWorkerMb: 2000,
      );
      expect(cap, 1);
    });

    test('never exceeds maxWorkers', () {
      final cap = PoolResourceBudget.workerCapacity(
        effectiveHeadroomMb: 999999,
        maxWorkers: 6,
        hashPerWorkerMb: 100,
      );
      expect(cap, 6);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // isWithinCeiling — THE CRITICAL INVARIANT
  // ════════════════════════════════════════════════════════════════════

  group('isWithinCeiling', () {
    test('workers within budget are within ceiling', () {
      expect(
        PoolResourceBudget.isWithinCeiling(
          totalRamMb: 32768,
          maxLoadPercent: 90.0,
          otherUsedMb: 9830,
          workerCount: 7,
          hashPerWorkerMb: 2000,
        ),
        isTrue,
      );
    });

    test('overloaded workers exceed ceiling', () {
      expect(
        PoolResourceBudget.isWithinCeiling(
          totalRamMb: 32768,
          maxLoadPercent: 90.0,
          otherUsedMb: 9830,
          workerCount: 7,
          hashPerWorkerMb: 5000, // way too much
        ),
        isFalse,
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // compute() — full pipeline end-to-end
  // ════════════════════════════════════════════════════════════════════

  group('compute() end-to-end', () {
    test('32GB desktop, 90% ceiling, fresh pool — all 7 workers fit', () {
      final budget = PoolResourceBudget.compute(
        system: desktop32gb,
        maxLoadPercent: 90.0,
        maxWorkers: 7,
        hashCeilingMb: 4000,
      );

      expect(budget.workerCapacity, 7);
      expect(budget.hashPerWorkerMb, greaterThanOrEqualTo(kMinHashMb));
      expect(budget.hashPerWorkerMb, lessThanOrEqualTo(4000));

      // CRITICAL: total allocation must fit within ceiling
      final otherUsed = desktop32gb.usedRamMb;
      expect(
        PoolResourceBudget.isWithinCeiling(
          totalRamMb: desktop32gb.totalRamMb,
          maxLoadPercent: 90.0,
          otherUsedMb: otherUsed,
          workerCount: budget.workerCapacity,
          hashPerWorkerMb: budget.hashPerWorkerMb,
        ),
        isTrue,
        reason: 'Total allocation must stay within 90% ceiling',
      );
    });

    test('16GB laptop, 90% ceiling, fresh pool', () {
      final budget = PoolResourceBudget.compute(
        system: laptop16gb,
        maxLoadPercent: 90.0,
        maxWorkers: 3,
        hashCeilingMb: 3000,
      );

      expect(budget.workerCapacity, greaterThanOrEqualTo(1));
      expect(budget.workerCapacity, lessThanOrEqualTo(3));

      expect(
        PoolResourceBudget.isWithinCeiling(
          totalRamMb: laptop16gb.totalRamMb,
          maxLoadPercent: 90.0,
          otherUsedMb: laptop16gb.usedRamMb,
          workerCount: budget.workerCapacity,
          hashPerWorkerMb: budget.hashPerWorkerMb,
        ),
        isTrue,
      );
    });

    test('8GB low-end, 90% ceiling, heavy load — graceful degradation', () {
      final budget = PoolResourceBudget.compute(
        system: lowEnd8gb,
        maxLoadPercent: 90.0,
        maxWorkers: 1,
        hashCeilingMb: 2048,
      );

      expect(budget.workerCapacity, 1);
      expect(budget.hashPerWorkerMb, greaterThanOrEqualTo(kMinHashMb));

      expect(
        PoolResourceBudget.isWithinCeiling(
          totalRamMb: lowEnd8gb.totalRamMb,
          maxLoadPercent: 90.0,
          otherUsedMb: lowEnd8gb.usedRamMb,
          workerCount: budget.workerCapacity,
          hashPerWorkerMb: budget.hashPerWorkerMb,
        ),
        isTrue,
      );
    });

    test('4GB near-full system, 90% ceiling — minimal but functional', () {
      final budget = PoolResourceBudget.compute(
        system: tinyBox4gb,
        maxLoadPercent: 90.0,
        maxWorkers: 1,
        hashCeilingMb: 512,
      );

      expect(budget.workerCapacity, 1);
      expect(budget.hashPerWorkerMb, kMinHashMb);
    });

    // ── Re-evaluation with existing workers (the OOM bug scenario) ──

    test('re-evaluation with 7 existing workers does NOT kill them', () {
      // Simulate: 7 workers already running at 2678 MB each.
      // OS reports 28.5 GB used because our workers consume RAM.
      const systemAfterSpawn = SystemSnapshot(
        totalRamMb: 31791,
        freeRamMb: 3244, // only 3 GB "free" but 20 GB is ours
        logicalCores: 8,
      );
      const existingPool = PoolState(workerCount: 7, hashPerWorkerMb: 2678);

      final budget = PoolResourceBudget.compute(
        system: systemAfterSpawn,
        maxLoadPercent: 90.0,
        maxWorkers: 7,
        hashCeilingMb: 4000,
        pool: existingPool,
      );

      // Must NOT shrink to 1 worker — our own memory is reclaimable
      expect(budget.workerCapacity, 7,
          reason: 'Must keep all 7 workers — own allocation is reclaimable');
      expect(budget.hashPerWorkerMb, greaterThanOrEqualTo(kMinHashMb));

      // Effective headroom should include own allocation
      expect(budget.effectiveHeadroomMb,
          greaterThanOrEqualTo(existingPool.ownAllocationMb));
    });

    test('re-evaluation with workers — hash stays reasonable', () {
      const systemAfterSpawn = SystemSnapshot(
        totalRamMb: 31791,
        freeRamMb: 3244,
        logicalCores: 8,
      );
      const existingPool = PoolState(workerCount: 7, hashPerWorkerMb: 2678);

      final budget = PoolResourceBudget.compute(
        system: systemAfterSpawn,
        maxLoadPercent: 90.0,
        maxWorkers: 7,
        hashCeilingMb: 4000,
        pool: existingPool,
      );

      // Hash shouldn't wildly change from what workers already have
      final delta = (budget.hashPerWorkerMb - existingPool.hashPerWorkerMb).abs();
      expect(delta, lessThan(500),
          reason: 'Hash should be stable between evaluations');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // Parametric: ceiling invariant across many scenarios
  // ════════════════════════════════════════════════════════════════════

  group('ceiling invariant (parametric)', () {
    final systems = [
      ('32GB idle', desktop32gb),
      ('16GB moderate', laptop16gb),
      ('8GB heavy', lowEnd8gb),
      ('4GB near-full', tinyBox4gb),
    ];

    final ceilings = [50.0, 70.0, 80.0, 90.0, 100.0];
    final workerCounts = [1, 2, 4, 7];

    for (final (name, system) in systems) {
      for (final ceiling in ceilings) {
        for (final maxW in workerCounts) {
          if (maxW > system.logicalCores) continue;

          test('$name, ${ceiling.round()}% ceiling, $maxW max workers', () {
            final budget = PoolResourceBudget.compute(
              system: system,
              maxLoadPercent: ceiling,
              maxWorkers: maxW,
              hashCeilingMb: 4096,
            );

            // 1. Worker capacity is within bounds
            expect(budget.workerCapacity, greaterThanOrEqualTo(1));
            expect(budget.workerCapacity, lessThanOrEqualTo(maxW));

            // 2. Hash is within bounds
            expect(budget.hashPerWorkerMb, greaterThanOrEqualTo(kMinHashMb));
            expect(budget.hashPerWorkerMb, lessThanOrEqualTo(4096));

            // 3. CRITICAL: total doesn't exceed ceiling
            //    (except the minimum-1-worker case which is intentional)
            if (budget.workerCapacity > 1 || budget.hashPerWorkerMb > kMinHashMb) {
              expect(
                PoolResourceBudget.isWithinCeiling(
                  totalRamMb: system.totalRamMb,
                  maxLoadPercent: ceiling,
                  otherUsedMb: system.usedRamMb,
                  workerCount: budget.workerCapacity,
                  hashPerWorkerMb: budget.hashPerWorkerMb,
                ),
                isTrue,
                reason:
                    'Allocation must stay within $ceiling% of ${system.totalRamMb} MB '
                    '(other used: ${system.usedRamMb} MB, '
                    '${budget.workerCapacity} workers × '
                    '${budget.hashPerWorkerMb} MB hash)',
              );
            }
          });
        }
      }
    }
  });

  // ════════════════════════════════════════════════════════════════════
  // Scale-up simulation: adding workers one at a time
  // ════════════════════════════════════════════════════════════════════

  group('scale-up simulation', () {
    test('adding workers one by one never exceeds ceiling', () {
      const system = SystemSnapshot(
        totalRamMb: 32768,
        freeRamMb: 22000,
        logicalCores: 8,
      );
      const maxWorkers = 7;
      const ceiling = 90.0;
      const hashCeiling = 4096;

      // Initial budget
      var budget = PoolResourceBudget.compute(
        system: system,
        maxLoadPercent: ceiling,
        maxWorkers: maxWorkers,
        hashCeilingMb: hashCeiling,
      );

      final hashPerWorker = budget.hashPerWorkerMb;

      // Simulate adding workers one at a time, each consuming memory.
      var currentFreeRam = system.freeRamMb;

      for (int n = 1; n <= budget.workerCapacity; n++) {
        // Worker n consumes hash + overhead from free RAM
        currentFreeRam -= (hashPerWorker + kProcessOverheadMb);
        if (currentFreeRam < 0) currentFreeRam = 0;

        final otherUsed = system.totalRamMb - system.freeRamMb;
        final workerUsed = n * (hashPerWorker + kProcessOverheadMb);

        // Verify we haven't blown the ceiling
        final ceilingMb = (system.totalRamMb * ceiling / 100).round();
        expect(
          otherUsed + workerUsed,
          lessThanOrEqualTo(ceilingMb),
          reason: 'After spawning worker $n: '
              'other=$otherUsed + workers=$workerUsed = '
              '${otherUsed + workerUsed} must be ≤ $ceilingMb',
        );
      }
    });

    test('re-evaluating mid-scale-up preserves existing workers', () {
      const maxWorkers = 7;
      const ceiling = 90.0;
      const hashCeiling = 4096;

      // Step 1: fresh system → compute initial budget
      const system1 = SystemSnapshot(
        totalRamMb: 32768,
        freeRamMb: 22000,
        logicalCores: 8,
      );
      final budget1 = PoolResourceBudget.compute(
        system: system1,
        maxLoadPercent: ceiling,
        maxWorkers: maxWorkers,
        hashCeilingMb: hashCeiling,
      );

      // Step 2: simulate 3 workers running, re-evaluate
      final workerRam = 3 * (budget1.hashPerWorkerMb + kProcessOverheadMb);
      final system2 = SystemSnapshot(
        totalRamMb: 32768,
        freeRamMb: system1.freeRamMb - workerRam,
        logicalCores: 8,
      );
      final pool2 = PoolState(
        workerCount: 3,
        hashPerWorkerMb: budget1.hashPerWorkerMb,
      );

      final budget2 = PoolResourceBudget.compute(
        system: system2,
        maxLoadPercent: ceiling,
        maxWorkers: maxWorkers,
        hashCeilingMb: hashCeiling,
        pool: pool2,
      );

      // Must still allow all 7 workers
      expect(budget2.workerCapacity, maxWorkers,
          reason: 'Existing worker RAM is reclaimable — all 7 should still fit');

      // Hash should be similar to first computation
      final delta = (budget2.hashPerWorkerMb - budget1.hashPerWorkerMb).abs();
      expect(delta, lessThan(100),
          reason: 'Hash should be stable across re-evaluations');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // Edge cases
  // ════════════════════════════════════════════════════════════════════

  group('edge cases', () {
    test('0 maxWorkers returns hashCeiling clamped', () {
      final hash = PoolResourceBudget.hashForMaxWorkers(
        effectiveHeadroomMb: 10000,
        maxWorkers: 0,
        hashCeilingMb: 2048,
      );
      expect(hash, 2048);
    });

    test('1 worker on very constrained system', () {
      final budget = PoolResourceBudget.compute(
        system: const SystemSnapshot(
          totalRamMb: 2048,
          freeRamMb: 100,
          logicalCores: 1,
        ),
        maxLoadPercent: 90.0,
        maxWorkers: 1,
        hashCeilingMb: 512,
      );

      expect(budget.workerCapacity, 1);
      expect(budget.hashPerWorkerMb, kMinHashMb);
    });

    test('huge system, many workers, low ceiling', () {
      final budget = PoolResourceBudget.compute(
        system: const SystemSnapshot(
          totalRamMb: 131072, // 128 GB
          freeRamMb: 100000,
          logicalCores: 32,
        ),
        maxLoadPercent: 50.0, // aggressive ceiling
        maxWorkers: 31,
        hashCeilingMb: 4096,
      );

      // Even with 50% ceiling on 128 GB, should still fit many workers
      expect(budget.workerCapacity, greaterThanOrEqualTo(10));
      expect(budget.hashPerWorkerMb, lessThanOrEqualTo(4096));

      expect(
        PoolResourceBudget.isWithinCeiling(
          totalRamMb: 131072,
          maxLoadPercent: 50.0,
          otherUsedMb: 31072,
          workerCount: budget.workerCapacity,
          hashPerWorkerMb: budget.hashPerWorkerMb,
        ),
        isTrue,
      );
    });

    test('PoolState.ownAllocationMb calculation', () {
      const pool = PoolState(workerCount: 5, hashPerWorkerMb: 1000);
      expect(pool.ownAllocationMb, 5 * (1000 + kProcessOverheadMb));
    });

    test('ResourceBudget.totalAllocationMb calculation', () {
      const budget = ResourceBudget(
        hashPerWorkerMb: 1000,
        workerCapacity: 5,
        effectiveHeadroomMb: 10000,
      );
      expect(budget.totalAllocationMb, 5 * (1000 + kProcessOverheadMb));
    });
  });
}
