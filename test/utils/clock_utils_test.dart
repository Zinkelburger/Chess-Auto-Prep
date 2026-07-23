import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/clock_utils.dart';

void main() {
  group('clockSecondsFromComments', () {
    test('parses chess.com style [%clk H:MM:SS.t]', () {
      expect(
        clockSecondsFromComments(['[%clk 0:09:58.8]']),
        closeTo(598.8, 1e-9),
      );
      expect(clockSecondsFromComments(['[%clk 1:00:03]']), 3603.0);
    });

    test('finds the token among other comment text', () {
      expect(
        clockSecondsFromComments([
          'nice move',
          'played fast [%clk 0:00:30.1] here',
        ]),
        closeTo(30.1, 1e-9),
      );
    });

    test('null when absent', () {
      expect(clockSecondsFromComments(null), isNull);
      expect(clockSecondsFromComments([]), isNull);
      expect(clockSecondsFromComments(['just prose']), isNull);
    });
  });

  group('parseTimeControl', () {
    test('base+increment', () {
      expect(parseTimeControl('600+5'), (600, 5.0));
      expect(parseTimeControl('180+2'), (180, 2.0));
    });

    test('base only means zero increment', () {
      expect(parseTimeControl('300'), (300, 0.0));
    });

    test('unknown forms return nulls', () {
      expect(parseTimeControl('-'), (null, null));
      expect(parseTimeControl('?'), (null, null));
      expect(parseTimeControl('40/9000'), (null, null));
      expect(parseTimeControl(null), (null, null));
      expect(parseTimeControl(''), (null, null));
    });
  });

  group('moveTimeSeconds', () {
    test('same-side clock is two plies back, increment added back', () {
      // White's clocks at plies 0 and 2: 60 → 55 with a 2s increment means
      // the move at ply 2 took 60 − 55 + 2 = 7 seconds.
      final clocks = <double?>[60.0, 60.0, 55.0];
      expect(moveTimeSeconds(clocks, 2, 2.0), 7.0);
    });

    test('null for first moves and missing clocks', () {
      expect(moveTimeSeconds([60.0, 60.0, 55.0], 0, 0.0), isNull);
      expect(moveTimeSeconds([60.0, 60.0, 55.0], 1, 0.0), isNull);
      expect(moveTimeSeconds([null, 60.0, 55.0], 2, 0.0), isNull);
      expect(moveTimeSeconds([60.0, 60.0, null], 2, 0.0), isNull);
      expect(moveTimeSeconds([60.0, 60.0], 2, 0.0), isNull);
    });

    test('negative move time (corrupt clocks) is unavailable, not hasty', () {
      // Clock GAINED more than the increment — physically impossible.
      final clocks = <double?>[60.0, 60.0, 70.0];
      expect(moveTimeSeconds(clocks, 2, 2.0), isNull);
    });
  });
}
