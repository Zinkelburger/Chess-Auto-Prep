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

  test('a week or more is a date', () {
    expect(ago(const Duration(days: 8)), isNot(contains('ago')));
  });

  test('a clock that is a little fast does not count backwards', () {
    expect(relativeTime(now.add(const Duration(seconds: 30)), now: now), 'just now');
  });
}
