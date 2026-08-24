import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/tactics/services/flaw_tagger.dart';

/// Winning chance ([-1, 1]) for an expected score (0–1).
double _wc(double es) => 2 * es - 1;

const _middlegameFen =
    'r1bq1rk1/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP1QPPP/R4RK1 w - - 0 8';

List<String> _tags({
  bool isBlunder = true,
  double esBefore = 0.55,
  double esAfter = 0.35,
  double? esAfterPrevUserMove,
  double? esBeforeNextUserMove,
  bool userLost = true,
  String fenBefore = _middlegameFen,
  double? clockAfterSeconds,
  double? moveTimeSeconds,
  int? baseTimeSeconds,
}) {
  return buildFlawTags(
    isBlunder: isBlunder,
    wcBefore: _wc(esBefore),
    wcAfter: _wc(esAfter),
    wcAfterPrevUserMove: esAfterPrevUserMove != null
        ? _wc(esAfterPrevUserMove)
        : null,
    wcBeforeNextUserMove: esBeforeNextUserMove != null
        ? _wc(esBeforeNextUserMove)
        : null,
    userLost: userLost,
    fenBefore: fenBefore,
    clockAfterSeconds: clockAfterSeconds,
    moveTimeSeconds: moveTimeSeconds,
    baseTimeSeconds: baseTimeSeconds,
  );
}

void main() {
  group('classifyImpact', () {
    test('reversed: clearly winning to clearly losing', () {
      expect(classifyImpact(0.70, 0.30), 'reversed');
      expect(classifyImpact(kReversedEntryEs, kReversedExitEs), 'reversed');
    });

    test('squandered: near-decisive back to a slight edge', () {
      expect(classifyImpact(0.80, 0.55), 'squandered');
    });

    test('most severe wins: a huge swing is only reversed', () {
      expect(classifyImpact(0.90, 0.25), 'reversed');
    });

    test('no tag for ordinary swings', () {
      // A blunder-sized drop that starts below the winning bar.
      expect(classifyImpact(0.55, 0.35), isNull);
      // Winning but lands above the squandered exit.
      expect(classifyImpact(0.80, 0.65), isNull);
    });
  });

  group('classifyTempo', () {
    test('no tag at all without clock data', () {
      expect(
        classifyTempo(
          moveTimeSeconds: null,
          clockAfterSeconds: 100,
          baseTimeSeconds: 600,
        ),
        isNull,
      );
      expect(
        classifyTempo(
          moveTimeSeconds: 5,
          clockAfterSeconds: null,
          baseTimeSeconds: 600,
        ),
        isNull,
      );
    });

    test('relative thresholds when base time is known', () {
      // 600s base: low-clock below 30s, hasty below 6s.
      expect(
        classifyTempo(
          moveTimeSeconds: 10,
          clockAfterSeconds: 20,
          baseTimeSeconds: 600,
        ),
        'low-clock',
      );
      expect(
        classifyTempo(
          moveTimeSeconds: 3,
          clockAfterSeconds: 300,
          baseTimeSeconds: 600,
        ),
        'hasty',
      );
      expect(
        classifyTempo(
          moveTimeSeconds: 30,
          clockAfterSeconds: 300,
          baseTimeSeconds: 600,
        ),
        'unrushed',
      );
    });

    test('a 5-second move is hasty in classical but normal in bullet', () {
      expect(
        classifyTempo(
          moveTimeSeconds: 5,
          clockAfterSeconds: 2000,
          baseTimeSeconds: 5400,
        ),
        'hasty',
      );
      expect(
        classifyTempo(
          moveTimeSeconds: 5,
          clockAfterSeconds: 30,
          baseTimeSeconds: 60,
        ),
        'unrushed',
      );
    });

    test('absolute fallbacks when base time is unknown', () {
      expect(
        classifyTempo(
          moveTimeSeconds: 10,
          clockAfterSeconds: 25,
          baseTimeSeconds: null,
        ),
        'low-clock',
      );
      expect(
        classifyTempo(
          moveTimeSeconds: 3,
          clockAfterSeconds: 100,
          baseTimeSeconds: null,
        ),
        'hasty',
      );
    });

    test('low-clock outranks hasty', () {
      expect(
        classifyTempo(
          moveTimeSeconds: 1,
          clockAfterSeconds: 10,
          baseTimeSeconds: 600,
        ),
        'low-clock',
      );
    });
  });

  group('buildFlawTags', () {
    test('always carries exactly one phase tag', () {
      expect(_tags(), ['middlegame']);
      expect(
        _tags(
          fenBefore: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        ),
        ['opening'],
      );
    });

    test('miss: the opponent handed us something right before our error', () {
      // Opponent's move raised our ES from 0.40 to 0.55 (a 15-point gift).
      expect(
        _tags(esAfterPrevUserMove: 0.40, esBefore: 0.55),
        contains('miss'),
      );
      // A small rise is not a miss.
      expect(
        _tags(esAfterPrevUserMove: 0.50, esBefore: 0.55),
        isNot(contains('miss')),
      );
      // First user move: no preceding context, no tag.
      expect(_tags(esAfterPrevUserMove: null), isNot(contains('miss')));
    });

    test('lucky: only blunders whose reply let us off the hook', () {
      // Our ES recovered from 0.35 to 0.55 across the opponent's reply.
      expect(
        _tags(esAfter: 0.35, esBeforeNextUserMove: 0.55),
        contains('lucky'),
      );
      // The opponent capitalized — not lucky.
      expect(
        _tags(esAfter: 0.35, esBeforeNextUserMove: 0.30),
        isNot(contains('lucky')),
      );
      // Mistakes never get the tag, even when unpunished.
      expect(
        _tags(isBlunder: false, esAfter: 0.35, esBeforeNextUserMove: 0.55),
        isNot(contains('lucky')),
      );
    });

    test('end-of-game lucky rule keys off the result', () {
      // Blunder, then we resigned/flagged: a loss, not an escape.
      expect(
        _tags(esBeforeNextUserMove: null, userLost: true),
        isNot(contains('lucky')),
      );
      // Blunder at game end without losing (draw / opponent resigned).
      expect(
        _tags(esBeforeNextUserMove: null, userLost: false),
        contains('lucky'),
      );
    });

    test('impact and tempo ride along in order', () {
      final tags = _tags(
        esBefore: 0.80,
        esAfter: 0.20,
        clockAfterSeconds: 10,
        moveTimeSeconds: 4,
        baseTimeSeconds: 600,
      );
      expect(tags, ['reversed', 'middlegame', 'low-clock']);
    });
  });
}
