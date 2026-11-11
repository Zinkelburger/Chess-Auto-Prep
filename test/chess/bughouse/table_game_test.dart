import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/table_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a drawn game is headed Draw, an unfinished one says nothing', () {
    expect(const TableGame({'Result': '1/2-1/2'}).heading, 'Draw');
    expect(const TableGame({'Result': '*'}).heading, '');
  });

  test('PGN\'s blanks name nobody', () {
    for (final blank in ['', ' ', '?', '-']) {
      expect(TableGame({'WhiteA': blank}).name(Seat.a), isNull, reason: blank);
    }
    expect(const TableGame({'WhiteA': 'larso'}).name(Seat.a), 'larso');
  });

  test('a clock shows hours from exactly one hour', () {
    expect(clockText(const Duration(minutes: 59, seconds: 59)), '59:59');
    expect(clockText(const Duration(hours: 1)), '1:00:00');
  });

  test('a clock shows tenths only below ten seconds', () {
    expect(clockText(const Duration(milliseconds: 9900)), '0:09.9');
    expect(clockText(const Duration(seconds: 10)), '0:10');
  });
}
