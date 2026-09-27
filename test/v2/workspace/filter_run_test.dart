import 'dart:async';

import 'package:chess_auto_prep/v2/chess/game_filter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/workspace/filter_run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'regex answers preserve header order and missing-value behavior',
    () async {
      final run = FilterRun.start(
        [
          [const PgnTag('Event', 'Tata Steel')],
          [const PgnTag('Event', 'Club night')],
          [],
        ],
        const GameFilter(
          rules: [
            HeaderRule(field: 'Event', rule: FilterRule.regex, value: '^Tata'),
          ],
        ),
      );
      addTearDown(run.cancel);
      expect(await run.result, [true, false, false]);
    },
  );

  test(
    'a pathological regex cannot block the caller or exceed its deadline',
    () async {
      final run = FilterRun.start(
        [
          [PgnTag('Event', '${List.filled(32, 'a').join()}!')],
        ],
        const GameFilter(
          rules: [
            HeaderRule(
              field: 'Event',
              rule: FilterRule.regex,
              value: r'^(a+)+$',
            ),
          ],
        ),
        timeout: const Duration(milliseconds: 200),
      );
      addTearDown(run.cancel);
      final ended = expectLater(run.result, throwsA(isA<TimeoutException>()));
      var responsive = false;
      Timer(const Duration(milliseconds: 20), () => responsive = true);
      await ended;
      expect(responsive, isTrue, reason: 'the caller keeps processing events');
    },
  );

  test(
    'cancelling during spawn completes without leaking a late answer',
    () async {
      final run = FilterRun.start([
        [const PgnTag('White', 'Carlsen')],
      ], const GameFilter(rules: [HeaderRule(value: 'Carlsen')]));
      run.cancel();
      expect(await run.result, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      run.cancel();
      expect(await run.result, isNull);
    },
  );
}
