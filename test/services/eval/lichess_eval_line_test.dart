import 'package:chess_auto_prep/services/eval/lichess_eval_line.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real lines from `lichess_db_eval.jsonl`, trimmed to a few PVs each.
const _simple =
    '{"fen":"7r/1p3k2/p1bPR3/5p2/2B2P1p/8/PP4P1/3K4 b - -","evals":'
    '[{"pvs":[{"cp":69,"line":"f7g7 e6e2 h8d8 e2d2"},'
    '{"cp":163,"line":"h8d8 d1e1 a6a5 a2a3"}],'
    '"knodes":4189972,"depth":46}]}';

/// Two evals; the deeper one is listed first here.
const _twoEvals =
    '{"fen":"8/4r3/2R2pk1/6pp/3P4/6P1/5K1P/8 b - -","evals":'
    '[{"pvs":[{"cp":0,"line":"e7a7 f2e3 a7a3"}],"knodes":491568,"depth":58},'
    '{"pvs":[{"cp":-25,"line":"e7e4 h2h4 g5h4"}],"knodes":1176702,"depth":57}]}';

/// The deepest eval is listed *second*, so order must not decide.
const _deepestLast =
    '{"fen":"8/4r3/2R2pk1/6pp/3P4/6P1/5K1P/8 w - -","evals":'
    '[{"pvs":[{"cp":11,"line":"c6c1 e7e4"}],"knodes":100,"depth":20},'
    '{"pvs":[{"cp":33,"line":"d4d5 g6f5"}],"knodes":200,"depth":44}]}';

/// Black mates: Lichess publishes the mate White-relative, so it is negative.
const _blackMates =
    '{"fen":"8/8/8/8/2n5/k7/2p5/KB6 b - -","evals":'
    '[{"pvs":[{"mate":-3,"line":"c2c1q b1c2 c4b2"},{"cp":0,"line":"a3b3 b1c2"}],'
    '"knodes":9000,"depth":40}]}';

/// White mates, and the PV promotes — the move must survive packing.
const _promotion =
    '{"fen":"8/P7/8/8/8/8/8/K6k w - -","evals":'
    '[{"pvs":[{"mate":7,"line":"a7a8q h1h2 a8a2"}],"knodes":50,"depth":36}]}';

void main() {
  group('parseLichessEvalLine', () {
    test('keeps the first PV of the only eval', () {
      final row = parseLichessEvalLine(_simple)!;
      expect(
        row.pos,
        positionKey('7r/1p3k2/p1bPR3/5p2/2B2P1p/8/PP4P1/3K4 b - -'),
      );
      expect(row.cp, 69);
      expect(row.mate, isNull);
      expect(row.depth, 46);
      expect(unpackUci(row.move), 'f7g7');
    });

    test('picks the deepest eval, whichever position it holds', () {
      expect(parseLichessEvalLine(_twoEvals)!.depth, 58);
      expect(parseLichessEvalLine(_twoEvals)!.cp, 0);

      final last = parseLichessEvalLine(_deepestLast)!;
      expect(last.depth, 44);
      expect(last.cp, 33);
      expect(unpackUci(last.move), 'd4d5');
    });

    test('mate is White-relative, so Black mating is negative', () {
      final row = parseLichessEvalLine(_blackMates)!;
      expect(row.mate, -3);
      expect(row.cp, isNull);
      expect(unpackUci(row.move), 'c2c1q');
    });

    test('a promoting best move round-trips', () {
      final row = parseLichessEvalLine(_promotion)!;
      expect(row.mate, 7);
      expect(unpackUci(row.move), 'a7a8q');
    });

    test('rubbish and blank lines are skipped, not thrown on', () {
      expect(parseLichessEvalLine(''), isNull);
      expect(parseLichessEvalLine('not json at all'), isNull);
      expect(parseLichessEvalLine('{"fen":"8/8/8/8/8/8/8/8 w - -"}'), isNull);
      expect(
        parseLichessEvalLine('{"fen":"8/8/8/8/8/8/8/8 w - -","evals":[]}'),
        isNull,
      );
    });

    test('an eval with no score is not mistaken for one', () {
      const noScore =
          '{"fen":"8/8/8/8/8/8/8/K6k w - -","evals":'
          '[{"pvs":[{"line":"a1a2"}],"knodes":1,"depth":5}]}';
      expect(parseLichessEvalLine(noScore), isNull);
    });

    test('a PV without a line still yields the score', () {
      const noLine =
          '{"fen":"8/8/8/8/8/8/8/K6k w - -","evals":'
          '[{"pvs":[{"cp":12}],"knodes":1,"depth":5}]}';
      final row = parseLichessEvalLine(noLine)!;
      expect(row.cp, 12);
      expect(row.move, 0);
      expect(unpackUci(row.move), isNull);
    });
  });

  group('packUci', () {
    test('round-trips plain and promoting moves', () {
      for (final uci in ['e2e4', 'a1h8', 'h8a1', 'a7a8q', 'b2b1n', 'g7g8r']) {
        expect(unpackUci(packUci(uci)), uci, reason: uci);
      }
    });

    test('every square survives', () {
      for (var from = 0; from < 64; from++) {
        final uci =
            '${String.fromCharCode(0x61 + from % 8)}'
            '${String.fromCharCode(0x31 + from ~/ 8)}e4';
        expect(unpackUci(packUci(uci)), uci);
      }
    });

    test('nonsense packs to the empty move', () {
      expect(packUci(''), 0);
      expect(packUci('e2'), 0);
      expect(packUci('z9z9'), 0);
      expect(packUci('e2e4x'), 0);
      expect(unpackUci(0), isNull);
    });
  });
}
