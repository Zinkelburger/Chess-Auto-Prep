import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/workspace/filter_run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/big_chapter.dart';

const _afterD4D5 = Fen(
  'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2',
);

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

  group('over the moves of a large file', () {
    // Every line opens 1. d4 d5; a game of another opening is put among
    // them, and one nothing could read.
    final lines = parseChapter(
      name: 'games',
      text:
          '${bigChapter(games: 1500)}'
          '[Event "English"]\n\n1. c4 e5 2. Nc3 *\n\n'
          '[Event "Broken"]\n[FEN "not a fen"]\n\n1. d4 d5 *\n',
    ).lines;
    final headers = [for (final line in lines) line.tags];
    final trees = [for (final line in lines) line.tree];

    test('a position is found in the games whose main line reaches it, with '
        'the caller served while they are searched', () async {
      var served = 0;
      final ticking = Timer.periodic(Duration.zero, (_) => served++);
      addTearDown(ticking.cancel);
      final run = FilterRun.start(
        headers,
        const GameFilter(position: _afterD4D5),
        trees: trees,
      );
      addTearDown(run.cancel);
      final passes = (await run.result)!;
      expect(passes, hasLength(1502));
      expect(passes.take(1500), everyElement(isTrue));
      expect(passes.skip(1500), [false, false]);
      expect(served, greaterThan(0));
    });

    test('a rule on the moves reads each main line', () async {
      final run = FilterRun.start(
        headers,
        const GameFilter(
          rules: [
            HeaderRule(
              field: movesField,
              rule: FilterRule.startsWith,
              value: 'c4 e5',
            ),
          ],
        ),
        trees: trees,
      );
      addTearDown(run.cancel);
      final passes = (await run.result)!;
      expect(
        [
          for (final (index, pass) in passes.indexed)
            if (pass) index,
        ],
        [1500],
      );
    });

    test(
      'a position and a rule together keep the games that pass both',
      () async {
        final run = FilterRun.start(
          headers,
          const GameFilter(
            position: _afterD4D5,
            rules: [HeaderRule(field: 'Event', value: 'Line 7')],
          ),
          trees: trees,
        );
        addTearDown(run.cancel);
        final passes = (await run.result)!;
        // Line 7, Line 70 to 79, Line 700 to 799.
        expect(passes.where((pass) => pass), hasLength(111));
      },
    );

    test('a position searched for with no moves given finds no game', () async {
      final run = FilterRun.start(
        headers,
        const GameFilter(position: _afterD4D5),
      );
      addTearDown(run.cancel);
      expect(await run.result, everyElement(isFalse));
    });

    test('a search stopped while the moves are read answers null', () async {
      final run = FilterRun.start(
        headers,
        const GameFilter(position: _afterD4D5),
        trees: trees,
      );
      run.cancel();
      expect(await run.result, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await run.result, isNull);
    });
  });

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
