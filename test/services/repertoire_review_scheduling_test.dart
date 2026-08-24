import 'dart:math';

import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fuzz is a spread, not a value under test — pin it to the middle so
/// scheduling assertions are about the scheduler.
class _NoFuzz implements Random {
  @override
  double nextDouble() => 0.5;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

RepertoireReviewEntry _entry({double ease = 2.5, double interval = 0}) =>
    RepertoireReviewEntry(
      repertoireId: 'rep',
      lineId: 'line',
      lineName: 'line',
      difficulty: ease,
      intervalDays: interval,
      lastRating: interval > 0 ? 'good' : '',
    );

void main() {
  final service = RepertoireReviewService(fuzz: _NoFuzz());

  group('applyRating', () {
    test('a new line graduates onto a fixed first step', () {
      expect(
        service.applyRating(_entry(), ReviewRating.good).intervalDays,
        1.0,
      );
      expect(
        service.applyRating(_entry(), ReviewRating.easy).intervalDays,
        3.0,
      );
      expect(
        service.applyRating(_entry(), ReviewRating.hard).intervalDays,
        1.0,
      );
    });

    test('Good multiplies by the ease, which Easy raises and Hard lowers', () {
      final graduated = _entry(interval: 10);
      expect(
        service.applyRating(graduated, ReviewRating.good).intervalDays,
        closeTo(25, 0.001),
      );

      // Easy also earns a higher ease for next time.
      final easy = service.applyRating(graduated, ReviewRating.easy);
      expect(easy.difficulty, closeTo(2.65, 0.001));
      expect(easy.intervalDays, closeTo(10 * 2.65 * 1.3, 0.001));

      final hard = service.applyRating(graduated, ReviewRating.hard);
      expect(hard.difficulty, closeTo(2.35, 0.001));
      expect(hard.intervalDays, closeTo(12, 0.001));
    });

    test('the ease is read, not just written — a Hard streak slows growth', () {
      var entry = _entry(interval: 10);
      for (var i = 0; i < 8; i++) {
        entry = service.applyRating(entry, ReviewRating.hard);
      }
      expect(entry.difficulty, closeTo(RepertoireReviewService.minEase, 1e-9));

      final slowed = service.applyRating(entry, ReviewRating.good);
      final fresh = service.applyRating(
        _entry(interval: entry.intervalDays),
        ReviewRating.good,
      );
      expect(
        slowed.intervalDays,
        lessThan(fresh.intervalDays),
        reason: 'the lowered ease has to actually shorten the next interval',
      );
    });

    test('Again sends the line back into the session, due now', () {
      final again = service.applyRating(
        _entry(interval: 30),
        ReviewRating.again,
      );
      expect(again.intervalDays, 0);
      expect(again.isDue, isTrue);
      expect(again.difficulty, closeTo(2.3, 0.001));
    });

    test('Hard always moves, so a 1-day line cannot stick there', () {
      var entry = _entry(interval: 1);
      entry = service.applyRating(entry, ReviewRating.hard);
      expect(entry.intervalDays, greaterThan(1));
    });

    test('intervals are capped', () {
      final huge = service.applyRating(
        _entry(interval: 300),
        ReviewRating.easy,
      );
      expect(huge.intervalDays, RepertoireReviewService.maxIntervalDays);
    });

    test('legacy eases outside the SM-2 range are clamped on use', () {
      final ancient = service.applyRating(
        _entry(ease: 9, interval: 10),
        ReviewRating.good,
      );
      expect(
        ancient.difficulty,
        closeTo(RepertoireReviewService.maxEase, 1e-9),
      );

      final floored = service.applyRating(
        _entry(ease: 0.2, interval: 10),
        ReviewRating.good,
      );
      expect(
        floored.difficulty,
        closeTo(RepertoireReviewService.minEase, 1e-9),
      );
    });
  });

  group('fuzz', () {
    test('spreads lines learned together across different days', () {
      // A whole course rated Good on the same interval must not all come back
      // on the same day.
      final fuzzy = RepertoireReviewService(fuzz: Random(7));
      final intervals = {
        for (var i = 0; i < 40; i++)
          fuzzy
              .applyRating(_entry(interval: 20), ReviewRating.good)
              .intervalDays,
      };
      expect(intervals.length, greaterThan(20));
      for (final interval in intervals) {
        expect(interval, closeTo(50, 50 * 0.05 + 0.001));
      }
    });

    test('leaves sub-2-day intervals alone', () {
      final fuzzy = RepertoireReviewService(fuzz: Random(1));
      expect(fuzzy.applyRating(_entry(), ReviewRating.good).intervalDays, 1.0);
      expect(fuzzy.applyRating(_entry(), ReviewRating.again).intervalDays, 0);
    });
  });

  group('previewInterval', () {
    test('shows the unfuzzed number the buttons promise', () {
      final entry = _entry(interval: 10);
      expect(service.previewInterval(entry, ReviewRating.good), closeTo(25, 0));
      expect(service.previewInterval(entry, ReviewRating.again), 0);
      // Preview must not schedule anything.
      expect(entry.intervalDays, 10);
    });
  });

  group('formatInterval', () {
    test('a zero interval reads as "now", not as a rounding artefact', () {
      expect(RepertoireReviewService.formatInterval(0), 'now');
      expect(RepertoireReviewService.formatInterval(1), '1d');
      expect(RepertoireReviewService.formatInterval(1 / 48), '<1m');
    });
  });
}
