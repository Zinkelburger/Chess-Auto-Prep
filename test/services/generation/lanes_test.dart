/// [runLanes] and [LaneGate]: the bounded work-stealing the build loop, the
/// coverage sweep and eval enrichment share.
library;

import 'dart:async';

import 'package:chess_auto_prep/services/generation/lanes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runLanes', () {
    test('never runs more than the lane count at once, and finishes every '
        'item', () async {
      var inFlight = 0;
      var peak = 0;
      final done = <int>[];
      await runLanes(
        List.generate(10, (i) => i),
        lanes: 3,
        task: (i) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          inFlight--;
          done.add(i);
        },
      );
      expect(peak, 3);
      expect(done, unorderedEquals(List.generate(10, (i) => i)));
    });

    test('a single lane is plain sequential order', () async {
      final order = <int>[];
      await runLanes(
        [3, 1, 2],
        lanes: 1,
        task: (i) async {
          await Future<void>.delayed(Duration.zero);
          order.add(i);
        },
      );
      expect(order, [3, 1, 2]);
    });

    test('a slow item does not hold the other lanes back', () async {
      final done = <int>[];
      final slow = Completer<void>();
      final run = runLanes(
        [0, 1, 2, 3],
        lanes: 2,
        task: (i) async {
          if (i == 0) await slow.future;
          done.add(i);
        },
      );
      // Lane two works through everything while lane one waits on item 0.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(done, [1, 2, 3]);
      slow.complete();
      await run;
      expect(done, [1, 2, 3, 0]);
    });

    test(
      'stop is honoured before each item; in-flight items complete',
      () async {
        var stop = false;
        final done = <int>[];
        await runLanes(
          [0, 1, 2, 3, 4, 5],
          lanes: 2,
          stop: () => stop,
          task: (i) async {
            await Future<void>.delayed(Duration.zero);
            done.add(i);
            // Item 0 stops the run while item 1 is already in flight: the
            // lane that finished 0 hands out nothing more, and item 1
            // completes.
            if (i == 0) stop = true;
          },
        );
        expect(done, [0, 1]);
      },
    );

    test('lanes are clamped to the item count and to at least one', () async {
      var started = 0;
      await runLanes([1], lanes: 8, task: (_) async => started++);
      expect(started, 1);
      await runLanes([1, 2], lanes: 0, task: (_) async => started++);
      expect(started, 3);
    });

    test('empty input returns without running anything', () async {
      var ran = false;
      await runLanes(<int>[], lanes: 4, task: (_) async => ran = true);
      expect(ran, isFalse);
    });
  });

  group('LaneGate', () {
    test('signal wakes every waiter exactly once', () async {
      final gate = LaneGate();
      var woken = 0;
      final a = gate.changed.then((_) => woken++);
      final b = gate.changed.then((_) => woken++);
      gate.signal();
      await Future.wait([a, b]);
      expect(woken, 2);

      // A later wait needs a later signal.
      var late = false;
      final c = gate.changed.then((_) => late = true);
      await Future<void>.delayed(Duration.zero);
      expect(late, isFalse);
      gate.signal();
      await c;
      expect(late, isTrue);
    });
  });
}
