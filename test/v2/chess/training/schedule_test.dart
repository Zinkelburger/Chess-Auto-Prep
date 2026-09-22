import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 22, 12);
  const key = (source: '/r/KID/Main.pgn', id: 'line_a');
  const fresh = Review(key: key, lineName: 'Main');

  Review rate(Review review, Rating rating, {bool clean = true}) =>
      rated(review, rating, now: now, clean: clean, jitter: 0);

  group('a line rated for the first time', () {
    test('graduates onto one day for Hard and Good, three for Easy', () {
      expect(rate(fresh, Rating.hard).intervalDays, 1);
      expect(rate(fresh, Rating.good).intervalDays, 1);
      expect(rate(fresh, Rating.easy).intervalDays, 3);
    });

    test('Again is due again at once, so it stays in the sitting', () {
      final again = rate(fresh, Rating.again, clean: false);
      expect(again.intervalDays, 0);
      expect(again.dueAt(now), isTrue);
      expect(again.untrained, isFalse);
    });

    test('is dated, named and counted', () {
      final good = rate(fresh, Rating.good);
      expect(good.lastRating, 'good');
      expect(good.lastReviewed, now);
      expect(good.due, now.add(const Duration(days: 1)));
      expect((good.passes, good.fails), (1, 0));
      expect(rate(fresh, Rating.good, clean: false).fails, 1);
    });
  });

  group('a line with an interval', () {
    final tenDays = fresh.copyWith(intervalDays: 10, lastRating: 'good');

    test('stretches by its ease on Good, and more on Easy', () {
      expect(rate(tenDays, Rating.good).intervalDays, 25);
      expect(
        rate(tenDays, Rating.easy).intervalDays,
        closeTo(10 * 2.65 * 1.3, 1e-9),
      );
    });

    test('Hard always moves it on by at least a day', () {
      final oneDay = fresh.copyWith(intervalDays: 1, lastRating: 'hard');
      expect(rate(oneDay, Rating.hard).intervalDays, 2);
      expect(rate(tenDays, Rating.hard).intervalDays, 12);
    });

    test('never goes past a year', () {
      final long = tenDays.copyWith(intervalDays: 300);
      expect(rate(long, Rating.easy).intervalDays, maxIntervalDays);
    });

    test('is spread by up to 5%, at least a day, above two days', () {
      double spread(double jitter) => rated(
        tenDays,
        Rating.good,
        now: now,
        clean: true,
        jitter: jitter,
      ).intervalDays;
      expect(spread(1), closeTo(26.25, 1e-9));
      expect(spread(-1), closeTo(23.75, 1e-9));
      final oneDay = fresh.copyWith(intervalDays: 1.5, lastRating: 'good');
      expect(
        rated(
          oneDay,
          Rating.hard,
          now: now,
          clean: true,
          jitter: 1,
        ).intervalDays,
        3.5,
      );
    });
  });

  test('the ease moves by rating and stays within 1.3–3.0', () {
    expect(rate(fresh, Rating.again).ease, closeTo(2.3, 1e-9));
    expect(rate(fresh, Rating.hard).ease, closeTo(2.35, 1e-9));
    expect(rate(fresh, Rating.good).ease, 2.5);
    expect(rate(fresh, Rating.easy).ease, closeTo(2.65, 1e-9));
    expect(rate(fresh.copyWith(ease: 1.35), Rating.again).ease, minEase);
    expect(rate(fresh.copyWith(ease: 2.95), Rating.easy).ease, maxEase);
    // A row written with the old default of 5.0 is read as the ceiling.
    expect(rate(fresh.copyWith(ease: 5), Rating.good).ease, maxEase);
  });

  test('a rating button shows the interval without the spread', () {
    final tenDays = fresh.copyWith(intervalDays: 10, lastRating: 'good');
    expect(intervalFor(tenDays, Rating.good), 25);
    expect(intervalFor(fresh, Rating.easy), 3);
  });

  test('an untrained line is never due; a trained one is due on its day', () {
    expect(fresh.dueAt(now), isFalse);
    final good = rate(fresh, Rating.good);
    expect(good.dueAt(now), isFalse);
    expect(good.dueAt(now.add(const Duration(days: 1))), isTrue);
  });

  test('lines marked known are staggered over five days', () {
    final days = [
      for (var nth = 0; nth < 6; nth++)
        markedKnown(fresh, now: now, nth: nth).intervalDays,
    ];
    expect(days, [1, 1.5, 2, 2.5, 3, 1]);
    expect(markedKnown(fresh, now: now, nth: 0).lastRating, 'good');
  });

  test('a line marked unknown keeps its ease, tallies and exclusion', () {
    final trained = rate(
      fresh.copyWith(ease: 2.1, excluded: true),
      Rating.good,
    );
    final reset = markedUnknown(trained);
    expect(reset.untrained, isTrue);
    expect(reset.due, isNull);
    expect(reset.intervalDays, 0);
    expect((reset.ease, reset.passes, reset.excluded), (2.1, 1, true));
  });
}
