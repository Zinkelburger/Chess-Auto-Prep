/// [pgnHeaderSortKey] — the ordering behind the viewer's "Newest first" sort.
///
/// It exists because the games cache is a merge log: file order is fetch
/// history, so the game you played five minutes ago can sit at index 300 of
/// 312. Sorting by this key is what makes the counter agree with the
/// recent-games list.
library;

import 'package:chess_auto_prep/utils/pgn_date_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pgnHeaderSortKey', () {
    test('prefers UTC headers over the local ones', () {
      final key = pgnHeaderSortKey({
        'Date': '2020.01.01',
        'Time': '00:00:00',
        'UTCDate': '2026.07.30',
        'UTCTime': '18:42:07',
      });

      expect(key, '2026.07.30 18:42:07');
    });

    test('falls back to Date/Time when there are no UTC headers', () {
      expect(
        pgnHeaderSortKey({'Date': '2026.07.30', 'Time': '09:05:01'}),
        '2026.07.30 09:05:01',
      );
    });

    test('zero-pads so a plain string compare orders chronologically', () {
      final early = pgnHeaderSortKey({'Date': '2026.7.9', 'Time': '9:5:1'});
      final late = pgnHeaderSortKey({'Date': '2026.7.30', 'Time': '10:0:0'});

      expect(early, '2026.07.09 09:05:01');
      expect(early.compareTo(late), lessThan(0));
    });

    test('a missing time still orders by date, at the start of the day', () {
      expect(pgnHeaderSortKey({'Date': '2026.07.30'}), '2026.07.30 00:00:00');
    });

    test('same-day games are separated by their time', () {
      final morning = pgnHeaderSortKey({
        'UTCDate': '2026.07.30',
        'UTCTime': '08:00:00',
      });
      final evening = pgnHeaderSortKey({
        'UTCDate': '2026.07.30',
        'UTCTime': '20:00:00',
      });

      expect(morning.compareTo(evening), lessThan(0));
    });

    test('an unusable date is empty, so callers can sort it last', () {
      expect(pgnHeaderSortKey(const {}), '');
      expect(pgnHeaderSortKey({'Date': '????.??.??'}), '');
      expect(pgnHeaderSortKey({'Date': 'not a date'}), '');
    });

    test('a known year with unknown month/day still sorts against others', () {
      // "1983.??.??" — the placeholders become 00, which puts the game before
      // every dated game of that year rather than dropping it out of the order.
      expect(pgnHeaderSortKey({'Date': '1983.??.??'}), '1983.00.00 00:00:00');
    });

    test('garbage time fields do not poison the date', () {
      expect(
        pgnHeaderSortKey({'Date': '2026.07.30', 'Time': '99:99:99'}),
        '2026.07.30 00:00:00',
      );
    });
  });
}
