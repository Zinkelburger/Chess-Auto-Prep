import 'package:chess_auto_prep/features/tactics/models/tactics_note.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The box answers one question — what did the move you played cost? The
  // best move and its eval are shown on the solution line, next to the move
  // itself, so neither is repeated here.
  group('TacticsNote.display', () {
    test(
      'reduces the current terse format to the played move and its eval',
      () {
        expect(TacticsNote.display('h5 +0.5 → -2.1, Qf3 +0.5'), 'h5 -2.1');
      },
    );

    test('keeps mate scores', () {
      expect(TacticsNote.display('Kg2 #3 → +1.2, Qh7+ #3'), 'Kg2 +1.2');
    });

    test('rewrites the short-lived verbose eval format', () {
      const verbose =
          'Blunder: h5 dropped your eval from +0.5 to -2.1 '
          '(win chance 55% → 21%). Best was Qf3.';
      expect(TacticsNote.display(verbose), 'h5 -2.1');
    });

    test(
      'legacy percent notes keep the arc — they never recorded the move',
      () {
        // The pre-July-2026 import format. filterDisplayComment's
        // classification stripper used to eat "Blunder. … 69." and show
        // "2% to 48.9% …"; the evals are recovered by inverting the Lichess
        // win-chance formula (69.2% ≈ +2.2, 48.9% ≈ -0.1). With no played SAN
        // to name, a bare "-0.1" would say nothing, so the arc stays.
        const legacy =
            'Blunder. Win chance dropped from 69.2% to 48.9% '
            '(0.4%). Best was Qf3.';
        expect(TacticsNote.display(legacy), '+2.2 → -0.1');
      },
    );

    test('legacy percent rewrite saturates extreme win chances at ±10', () {
      const legacy =
          'Inaccuracy. Win chance dropped from 100.0% to 90.5% '
          '(-0.2%). Best was Rxe8.';
      expect(TacticsNote.display(legacy), '+10.0 → +6.1');
    });

    test('still strips engine tokens from scraped comments', () {
      expect(
        TacticsNote.display('[%eval -2.1] [%clk 0:01:30] Loses the exchange.'),
        'Loses the exchange.',
      );
    });

    test('user-authored prose is untouched', () {
      const note = 'Remember the knight fork on e7 in this structure.';
      expect(TacticsNote.display(note), note);
    });
  });

  group('TacticsNote.parse', () {
    test('splits the current terse format into its four parts', () {
      final parts = TacticsNote.parse('h5 +0.5 → -2.1, Qf3 +0.5')!;
      expect(parts.playedSan, 'h5');
      expect(parts.evalBefore, '+0.5');
      expect(parts.evalAfter, '-2.1');
      expect(parts.bestSan, 'Qf3');
      expect(parts.evalBest, '+0.5');
    });

    test('recovers the best move and its eval from a legacy percent note', () {
      final parts = TacticsNote.parse(
        'Blunder. Win chance dropped from 69.2% to 48.9% (0.4%). Best was Qf3.',
      )!;
      expect(parts.playedSan, isEmpty);
      expect(parts.bestSan, 'Qf3');
      expect(parts.evalBest, '+2.2');
    });

    test('handles mate scores on both sides of the arc', () {
      final parts = TacticsNote.parse('Kg2 #3 → +1.2, Qh7+ #3')!;
      expect(parts.playedSan, 'Kg2');
      expect(parts.evalAfter, '+1.2');
      expect(parts.bestSan, 'Qh7+');
      expect(parts.evalBest, '#3');
    });

    test('is null for prose and scraped comments', () {
      expect(TacticsNote.parse('Loses the exchange.'), isNull);
      expect(TacticsNote.parse(''), isNull);
      expect(
        TacticsNote.parse('Remember the knight fork on e7 in this structure.'),
        isNull,
      );
    });
  });

  // Reading is total over every format (see TacticsNote.parse); canonicalize
  // is what makes the upgrade stick, by running at decode so the next save
  // writes the current shape.
  group('TacticsNote.canonicalize', () {
    test('rewrites the legacy percent format', () {
      expect(
        TacticsNote.canonicalize(
          'Blunder. Win chance dropped from 69.2% to 48.9% '
          '(0.4%). Best was Qf3.',
        ),
        '+2.2 → -0.1, Qf3 +2.2',
      );
    });

    test('rewrites the short-lived verbose format', () {
      expect(
        TacticsNote.canonicalize(
          'Blunder: h5 dropped your eval from +0.5 to -2.1 '
          '(win chance 55% → 21%). Best was Qf3.',
        ),
        'h5 +0.5 → -2.1, Qf3 +0.5',
      );
    });

    test('leaves canonical notes and user prose exactly as they are', () {
      const canonical = 'h5 +0.5 → -2.1, Qf3 +0.5';
      expect(TacticsNote.canonicalize(canonical), canonical);
      const prose = 'Remember the knight fork on e7.';
      expect(TacticsNote.canonicalize(prose), prose);
      expect(TacticsNote.canonicalize(''), '');
    });

    test('is idempotent', () {
      const legacy =
          'Blunder. Win chance dropped from 69.2% to 48.9% (0.4%). '
          'Best was Qf3.';
      final once = TacticsNote.canonicalize(legacy);
      expect(TacticsNote.canonicalize(once), once);
    });
  });

  group('TacticsNote.compose', () {
    test('round-trips through parse', () {
      final text = TacticsNote.compose(
        playedSan: 'h5',
        evalBefore: '+0.5',
        evalAfter: '-2.1',
        bestSan: 'Qf3',
      );
      expect(text, 'h5 +0.5 → -2.1, Qf3 +0.5');
      final parts = TacticsNote.parse(text)!;
      expect(parts.playedSan, 'h5');
      expect(parts.evalBefore, '+0.5');
      expect(parts.evalAfter, '-2.1');
      expect(parts.bestSan, 'Qf3');
      expect(parts.evalBest, '+0.5');
    });

    test('formatEval writes what parse reads back', () {
      expect(TacticsNote.formatEval(scoreCp: 50), '+0.5');
      expect(TacticsNote.formatEval(scoreCp: 50, negate: true), '-0.5');
      expect(TacticsNote.formatEval(scoreMate: 3), '#3');
      expect(TacticsNote.formatEval(scoreMate: 3, negate: true), '#-3');
      final parts = TacticsNote.parse(
        TacticsNote.compose(
          playedSan: 'Kg2',
          evalBefore: TacticsNote.formatEval(scoreMate: 3),
          evalAfter: TacticsNote.formatEval(scoreCp: 120),
          bestSan: 'Qh7+',
        ),
      )!;
      expect(parts.evalBefore, '#3');
      expect(parts.evalAfter, '+1.2');
    });
  });
}
