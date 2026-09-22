import 'package:chess_auto_prep/v2/ui/relative_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 19, 14, 30);

  String ago(Duration since) => relativeTime(now.subtract(since), now: now);

  test('the last minute is just now', () {
    expect(ago(const Duration(seconds: 40)), 'just now');
    expect(ago(Duration.zero), 'just now');
  });

  test('minutes, hours and days', () {
    expect(ago(const Duration(minutes: 5)), '5m ago');
    expect(ago(const Duration(hours: 4)), '4h ago');
    expect(ago(const Duration(days: 3)), '3d ago');
  });

  test('each unit changes on its own boundary, not a moment before', () {
    expect(ago(const Duration(seconds: 59)), 'just now');
    expect(ago(const Duration(seconds: 60)), '1m ago');
    expect(ago(const Duration(minutes: 59)), '59m ago');
    expect(ago(const Duration(minutes: 60)), '1h ago');
    expect(ago(const Duration(hours: 23)), '23h ago');
    expect(ago(const Duration(hours: 24)), '1d ago');
    expect(ago(const Duration(days: 6, hours: 23)), '6d ago');
  });

  test('a week or more is a date', () {
    expect(ago(const Duration(days: 7)), 'Sep 12, 2026');
    expect(ago(const Duration(days: 8)), isNot(contains('ago')));
  });

  test('a clock that is a little fast does not count backwards', () {
    expect(
      relativeTime(now.add(const Duration(seconds: 30)), now: now),
      'just now',
    );
  });
}
