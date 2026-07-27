import 'package:chess_auto_prep/screens/repertoire/generation_notification_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// These rules lived inline in RepertoireScreen's generation listener, where
/// nothing could test them — and both exist because of a fixed performance
/// bug. Extracted, they are checkable.

/// Stand-in for a BuildTree. Identity is what matters: a run mutates one tree
/// in place, so the router must compare by reference, not value.
class _Tree {
  _Tree(this.label);
  final String label;
}

void main() {
  late GenerationNotificationRouter router;

  setUp(() => router = GenerationNotificationRouter());

  group('justFinished', () {
    test('is false on the tick that starts a run', () {
      final a = router.onNotified(isGenerating: true, generatedTree: null);
      expect(a.justFinished, isFalse);
    });

    test('is false while a run is in progress', () {
      router.onNotified(isGenerating: true, generatedTree: null);
      final a = router.onNotified(isGenerating: true, generatedTree: null);
      expect(a.justFinished, isFalse);
    });

    test('fires exactly once on the generating -> idle edge', () {
      router.onNotified(isGenerating: true, generatedTree: null);
      final ending = router.onNotified(
        isGenerating: false,
        generatedTree: null,
      );
      expect(ending.justFinished, isTrue);

      final after = router.onNotified(isGenerating: false, generatedTree: null);
      expect(
        after.justFinished,
        isFalse,
        reason: 'the outcome snackbar must not repeat on later notifications',
      );
    });

    test(
      'does not fire when a notification arrives while idle from the start',
      () {
        final a = router.onNotified(isGenerating: false, generatedTree: null);
        expect(a.justFinished, isFalse);
      },
    );
  });

  group('coherence gating', () {
    test('does not run when there is no tree', () {
      final a = router.onNotified(isGenerating: true, generatedTree: null);
      expect(a.shouldRunCoherence, isFalse);
    });

    test('runs the first time a tree appears', () {
      final a = router.onNotified(
        isGenerating: true,
        generatedTree: _Tree('t'),
      );
      expect(a.shouldRunCoherence, isTrue);
    });

    test('does NOT re-run for the same tree on later progress ticks', () {
      final tree = _Tree('t');
      router.onNotified(isGenerating: true, generatedTree: tree);
      for (var i = 0; i < 20; i++) {
        final a = router.onNotified(isGenerating: true, generatedTree: tree);
        expect(
          a.shouldRunCoherence,
          isFalse,
          reason: 'this fired several times a second for whole builds',
        );
      }
    });

    test('re-runs when a different tree object appears', () {
      router.onNotified(isGenerating: true, generatedTree: _Tree('first'));
      final a = router.onNotified(
        isGenerating: true,
        generatedTree: _Tree('second'),
      );
      expect(a.shouldRunCoherence, isTrue);
    });

    test('compares by identity, not equality', () {
      // Two distinct objects that would compare equal under a value-based
      // check must still count as different trees.
      final a = _Tree('same');
      final b = _Tree('same');
      router.onNotified(isGenerating: true, generatedTree: a);
      expect(
        router
            .onNotified(isGenerating: true, generatedTree: b)
            .shouldRunCoherence,
        isTrue,
      );
    });

    test('re-runs on completion even for the tree it already clustered', () {
      final tree = _Tree('t');
      router.onNotified(isGenerating: true, generatedTree: tree);
      final done = router.onNotified(isGenerating: false, generatedTree: tree);
      expect(
        done.shouldRunCoherence,
        isTrue,
        reason: 'the finished tree has selection flags the partial one lacked',
      );
    });
  });

  group('rebuild coalescing', () {
    test('coalesces while generating', () {
      final a = router.onNotified(isGenerating: true, generatedTree: null);
      expect(a.shouldCoalesceRebuild, isTrue);
    });

    test('paints immediately once the run ends', () {
      router.onNotified(isGenerating: true, generatedTree: null);
      final done = router.onNotified(isGenerating: false, generatedTree: null);
      expect(
        done.shouldCoalesceRebuild,
        isFalse,
        reason: 'the final state must not wait out a throttle timer',
      );
    });
  });

  test('a second run after the first behaves like a fresh one', () {
    final first = _Tree('first');
    router.onNotified(isGenerating: true, generatedTree: first);
    router.onNotified(isGenerating: false, generatedTree: first);

    final second = _Tree('second');
    final start = router.onNotified(isGenerating: true, generatedTree: second);
    expect(start.justFinished, isFalse);
    expect(start.shouldRunCoherence, isTrue);
    expect(start.shouldCoalesceRebuild, isTrue);

    final end = router.onNotified(isGenerating: false, generatedTree: second);
    expect(end.justFinished, isTrue);
  });
}
