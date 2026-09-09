/// [GenerationProgress] — the throttled progress object the Jobs panel
/// reads: notification coalescing, the job-card sync, the elapsed ticker.
library;

import 'package:chess_auto_prep/core/generation_progress.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness({this.withJob = true});

  final bool withJob;
  int notifies = 0;
  bool running = true;
  bool paused = false;
  final Stopwatch stopwatch = Stopwatch()..start();
  late final RepertoireJob? job = withJob
      ? RepertoireJob(id: 'j', type: JobType.generation, label: 'build')
      : null;

  late final GenerationProgress progress = GenerationProgress(
    notify: () => notifies++,
    job: () => job,
    isRunning: () => running,
    isPaused: () => paused,
    elapsed: () => stopwatch,
  );
}

void main() {
  test('the first update notifies at once and syncs the job card', () {
    final h = _Harness();
    h.progress.phase = GenerationPhase.buildingTree;

    h.progress.update(nodes: 42, depth: 2, maxPlyConfig: 8);

    expect(h.notifies, 1);
    expect(h.progress.nodes, 42);
    final jp = h.job!.progress;
    expect(jp.nodesProcessed, 42);
    expect(jp.message, contains('42 nodes'));
    expect(jp.message, contains('Depth 2/8'));
    h.progress.dispose();
  });

  test(
    'updates inside the throttle window coalesce to one late notify',
    () async {
      final h = _Harness();

      h.progress.update(nodes: 1);
      h.progress.update(nodes: 2);
      h.progress.update(nodes: 3);
      expect(h.notifies, 1);
      // The fields are live immediately; only the notification waits.
      expect(h.progress.nodes, 3);
      expect(h.job!.progress.nodesProcessed, 1);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(h.notifies, 2);
      expect(h.job!.progress.nodesProcessed, 3);
      h.progress.dispose();
    },
  );

  test(
    'setStatus flushes through the throttle and cancels the timer',
    () async {
      final h = _Harness();

      h.progress.update(nodes: 1);
      h.progress.update(nodes: 2); // deferred
      h.progress.setStatus('Building tree', GenerationPhase.buildingTree);
      expect(h.notifies, 2);
      expect(h.progress.status, 'Building tree');
      expect(h.job!.progress.nodesProcessed, 2);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(h.notifies, 2, reason: 'the deferred notify was absorbed');
      h.progress.dispose();
    },
  );

  test('dispose drops a pending notify', () async {
    final h = _Harness();

    h.progress.update(nodes: 1);
    h.progress.update(nodes: 2);
    h.progress.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.notifies, 1);
  });

  test('no job: fields still update and listeners are still told', () {
    final h = _Harness(withJob: false);

    h.progress.update(nodes: 5, lines: 2);

    expect(h.notifies, 1);
    expect(h.progress.nodes, 5);
    expect(h.progress.lines, 2);
    h.progress.dispose();
  });

  group('handleBuildProgress', () {
    test('copies every live field and reads elapsed from the stopwatch', () {
      final h = _Harness();

      h.progress.handleBuildProgress(
        const BuildProgress(
          totalNodes: 120,
          currentDepth: 6,
          maxPlyConfig: 12,
          unexploredAtDepth: 3,
          totalAtDepth: 10,
          nodesPerMinute: 400,
          etaDepthSeconds: 15,
          bestFirst: true,
          frontierSize: 7,
          priorityProgress: 0.4,
          etaRunSeconds: 90,
          depthTotals: [1, 2, 4],
          depthExplored: [1, 2, 0],
          elapsedMs: 999999, // ignored: the session's stopwatch is the clock
        ),
      );

      final p = h.progress;
      expect(p.nodes, 120);
      expect(p.depth, 6);
      expect(p.maxPlyConfig, 12);
      expect(p.unexploredAtDepth, 3);
      expect(p.totalAtDepth, 10);
      expect(p.nodesPerMinute, 400);
      expect(p.etaDepthSec, 15.0);
      expect(p.bestFirst, isTrue);
      expect(p.frontier, 7);
      expect(p.priorityFraction, 0.4);
      expect(p.runEtaSec, 90);
      expect(p.depthTotals, [1, 2, 4]);
      expect(p.depthExplored, [1, 2, 0]);
      expect(p.elapsedMs, lessThan(999999));
      p.dispose();
    });

    test('a null depth ETA overwrites the previous layer\'s', () {
      final h = _Harness();

      h.progress.handleBuildProgress(
        const BuildProgress(totalNodes: 1, etaDepthSeconds: 30),
      );
      expect(h.progress.etaDepthSec, 30.0);

      h.progress.handleBuildProgress(const BuildProgress(totalNodes: 2));
      expect(h.progress.etaDepthSec, isNull);
      h.progress.dispose();
    });
  });

  group('job fraction', () {
    test('FIFO tree build blends depth and layer progress', () {
      final h = _Harness();
      h.progress.phase = GenerationPhase.buildingTree;

      h.progress.update(
        depth: 2,
        maxPlyConfig: 4,
        totalAtDepth: 4,
        unexploredAtDepth: 1,
      );

      // 0.5 of the depth at weight 0.85, 0.75 of the layer at weight 0.15.
      expect(h.job!.progress.fraction, closeTo(0.5 * 0.85 + 0.75 * 0.15, 1e-9));
      h.progress.dispose();
    });

    test('best-first uses the priority descent, clamped', () {
      final h = _Harness();
      h.progress.handleBuildProgress(
        const BuildProgress(
          totalNodes: 1,
          bestFirst: true,
          priorityProgress: 1.7,
        ),
      );
      h.progress.setStatus('Building', GenerationPhase.buildingTree);

      expect(h.job!.progress.fraction, 1.0);
      h.progress.dispose();
    });

    test('outside the tree build the bar has nothing to say', () {
      final h = _Harness();
      h.progress.setStatus('Selecting', GenerationPhase.selectingRepertoire);
      h.progress.update(depth: 3, maxPlyConfig: 4);

      expect(h.job!.progress.fraction, 0);
      expect(h.job!.progress.message, contains('nodes in tree'));
      h.progress.dispose();
    });
  });

  test('reset restores every field to its idle value', () {
    final h = _Harness();
    h.progress.handleBuildProgress(
      const BuildProgress(
        totalNodes: 9,
        currentDepth: 3,
        maxPlyConfig: 30,
        unexploredAtDepth: 1,
        totalAtDepth: 2,
        nodesPerMinute: 10,
        etaDepthSeconds: 5,
        bestFirst: true,
        frontierSize: 4,
        priorityProgress: 0.2,
        etaRunSeconds: 8,
        depthTotals: [1],
        depthExplored: [1],
      ),
    );
    h.progress.setStatus('x', GenerationPhase.verifying);
    h.progress.update(lines: 3);

    h.progress.reset();

    final p = h.progress;
    expect(p.status, '');
    expect(p.phase, GenerationPhase.idle);
    expect(p.nodes, 0);
    expect(p.depth, 0);
    expect(p.maxPlyConfig, 20);
    expect(p.unexploredAtDepth, 0);
    expect(p.totalAtDepth, 0);
    expect(p.lines, 0);
    expect(p.nodesPerMinute, isNull);
    expect(p.etaDepthSec, isNull);
    expect(p.elapsedMs, 0);
    expect(p.bestFirst, isFalse);
    expect(p.frontier, 0);
    expect(p.priorityFraction, isNull);
    expect(p.runEtaSec, isNull);
    expect(p.depthTotals, isEmpty);
    expect(p.depthExplored, isEmpty);
    p.dispose();
  });

  group('elapsed ticker', () {
    test('ticks once a second while running, and not while paused', () {
      fakeAsync((async) {
        final h = _Harness();
        h.progress.startElapsedTicker();

        async.elapse(const Duration(seconds: 3));
        final whileRunning = h.notifies;
        expect(whileRunning, greaterThanOrEqualTo(1));

        h.paused = true;
        async.elapse(const Duration(seconds: 3));
        // A deferred notify from the running phase may still land, but no
        // new tick reaches update().
        h.progress.flushNotify();
        final afterPause = h.notifies;
        async.elapse(const Duration(seconds: 3));
        expect(h.notifies, afterPause);

        h.progress.stopElapsedTicker();
        h.paused = false;
        async.elapse(const Duration(seconds: 3));
        expect(h.notifies, afterPause);
        h.progress.dispose();
      });
    });

    test('starting again replaces the previous ticker', () {
      fakeAsync((async) {
        final h = _Harness();
        h.progress.startElapsedTicker();
        h.progress.startElapsedTicker();
        h.progress.dispose();

        async.elapse(const Duration(seconds: 5));
        // Nothing survives dispose: no periodic timer, no deferred notify.
        expect(h.notifies, 0);
      });
    });
  });
}
