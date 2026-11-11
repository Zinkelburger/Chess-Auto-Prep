import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:flutter_test/flutter_test.dart';

String played(String? date) =>
    '${date == null ? '' : '[UTCDate "$date"]\n[UTCTime "10:00:00"]\n'}'
    '[TimeControl "300+0"]\n\n1. e4 *';

void main() {
  final now = DateTime(2026, 11, 15);

  test('a download takes 500 games unless told, between 1 and 10000', () {
    expect(const PlayerDownloadRange().max, 500);
    expect(PlayerDownloadRange.from(const {}).max, 500);
    expect(PlayerDownloadRange.from(const {'max': 0}).max, 1);
    expect(PlayerDownloadRange.from(const {'max': 20000}).max, 10000);
  });

  test('a window is 1 to 120 months', () {
    expect(PlayerDownloadRange.from(const {'months': 0}).months, 1);
    expect(PlayerDownloadRange.from(const {'months': 200}).months, 120);
  });

  test('a window of three months is this month and the two before', () {
    const range = PlayerDownloadRange(months: 3);
    expect(range.since(now), DateTime(2026, 9));
    expect(range.keeps(played('2026.09.01'), now), isTrue);
    expect(range.keeps(played('2026.08.31'), now), isFalse);
  });

  test('with a window, a game that says no date is left out; without one it '
      'is kept', () {
    expect(
      const PlayerDownloadRange(months: 3).keeps(played(null), now),
      isFalse,
    );
    expect(const PlayerDownloadRange().keeps(played(null), now), isTrue);
  });
}
