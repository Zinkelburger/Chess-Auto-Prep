import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/time_format.dart';

/// Pins the app's three time shapes, which four screens used to re-derive.
///
/// The cases that matter are the boundaries the old hand-rolled ladders each
/// got slightly differently: the first minute, the seven-day cut-off, and a
/// timestamp that is in the *future* — which the training panel's "Next
/// review" line was rendering with a past-tense formatter, producing
/// `-4320m ago`.
void main() {
  final now = DateTime(2026, 9, 4, 12, 0);

  group('formatTimeAgo', () {
    test('the first minute reads as just now, not 0m ago', () {
      expect(
        formatTimeAgo(now.subtract(const Duration(seconds: 5)), now: now),
        'just now',
      );
      expect(
        formatTimeAgo(now.subtract(const Duration(seconds: 59)), now: now),
        'just now',
      );
    });

    test('climbs minutes, hours, then days', () {
      expect(
        formatTimeAgo(now.subtract(const Duration(minutes: 4)), now: now),
        '4m ago',
      );
      expect(
        formatTimeAgo(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        formatTimeAgo(now.subtract(const Duration(days: 5)), now: now),
        '5d ago',
      );
    });

    test('past a week it shows the date, because "23d ago" says nothing', () {
      expect(formatTimeAgo(DateTime(2026, 7, 21), now: now), '7/21');
      expect(formatTimeAgo(DateTime(2025, 12, 3), now: now), '12/3');
    });

    test('a clock skew into the future does not print a negative count', () {
      expect(
        formatTimeAgo(now.add(const Duration(hours: 2)), now: now),
        'just now',
      );
    });
  });

  group('formatTimeUntil', () {
    test('a due date that has passed reads now', () {
      expect(
        formatTimeUntil(now.subtract(const Duration(days: 3)), now: now),
        'now',
      );
      expect(formatTimeUntil(now, now: now), 'now');
    });

    test('climbs minutes, hours, then days', () {
      expect(
        formatTimeUntil(now.add(const Duration(minutes: 12)), now: now),
        'in 12m',
      );
      expect(
        formatTimeUntil(now.add(const Duration(hours: 5)), now: now),
        'in 5h',
      );
      expect(
        formatTimeUntil(now.add(const Duration(days: 3)), now: now),
        'in 3d',
      );
    });

    test('past a week it shows the date', () {
      expect(formatTimeUntil(DateTime(2026, 10, 2), now: now), '10/2');
    });
  });

  group('formatCompactDuration', () {
    test('run and job elapsed times stay short', () {
      expect(formatCompactDuration(const Duration(seconds: 38)), '38s');
      expect(
        formatCompactDuration(const Duration(minutes: 4, seconds: 9)),
        '4m 09s',
      );
      expect(
        formatCompactDuration(const Duration(hours: 1, minutes: 12)),
        '1h 12m',
      );
    });

    test('seconds are zero-padded so a column of times lines up', () {
      expect(
        formatCompactDuration(const Duration(minutes: 2, seconds: 5)),
        '2m 05s',
      );
    });
  });

  group('formatCoarseDuration', () {
    test('coarse by design', () {
      expect(formatCoarseDuration(const Duration(seconds: 45)), '45 s');
      expect(formatCoarseDuration(const Duration(minutes: 12)), '12 min');
      expect(
        formatCoarseDuration(const Duration(hours: 3, minutes: 40)),
        '3 h 40 min',
      );
      expect(formatCoarseDuration(const Duration(hours: 5)), '5 h');
      expect(formatCoarseDuration(const Duration(days: 3)), '3 days');
    });
  });
}
