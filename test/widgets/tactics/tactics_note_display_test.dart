import 'package:chess_auto_prep/widgets/tactics/tactics_training_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The box answers one question — what did the move you played cost? The
  // best move and its eval are shown on the solution line, next to the move
  // itself, so neither is repeated here.
  group('displayTacticsNote', () {
    test(
      'reduces the current terse format to the played move and its eval',
      () {
        expect(displayTacticsNote('h5 +0.5 → -2.1, Qf3 +0.5'), 'h5 -2.1');
      },
    );

    test('keeps mate scores', () {
      expect(displayTacticsNote('Kg2 #3 → +1.2, Qh7+ #3'), 'Kg2 +1.2');
    });

    test('rewrites the short-lived verbose eval format', () {
      const verbose =
          'Blunder: h5 dropped your eval from +0.5 to -2.1 '
          '(win chance 55% → 21%). Best was Qf3.';
      expect(displayTacticsNote(verbose), 'h5 -2.1');
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
        expect(displayTacticsNote(legacy), '+2.2 → -0.1');
      },
    );

    test('legacy percent rewrite saturates extreme win chances at ±10', () {
      const legacy =
          'Inaccuracy. Win chance dropped from 100.0% to 90.5% '
          '(-0.2%). Best was Rxe8.';
      expect(displayTacticsNote(legacy), '+10.0 → +6.1');
    });

    test('still strips engine tokens from scraped comments', () {
      expect(
        displayTacticsNote('[%eval -2.1] [%clk 0:01:30] Loses the exchange.'),
        'Loses the exchange.',
      );
    });

    test('user-authored prose is untouched', () {
      const note = 'Remember the knight fork on e7 in this structure.';
      expect(displayTacticsNote(note), note);
    });
  });

  group('parseTacticsNote', () {
    test('splits the current terse format into its four parts', () {
      final parts = parseTacticsNote('h5 +0.5 → -2.1, Qf3 +0.5')!;
      expect(parts.playedSan, 'h5');
      expect(parts.evalBefore, '+0.5');
      expect(parts.evalAfter, '-2.1');
      expect(parts.bestSan, 'Qf3');
      expect(parts.evalBest, '+0.5');
    });

    test('recovers the best move and its eval from a legacy percent note', () {
      final parts = parseTacticsNote(
        'Blunder. Win chance dropped from 69.2% to 48.9% (0.4%). Best was Qf3.',
      )!;
      expect(parts.playedSan, isEmpty);
      expect(parts.bestSan, 'Qf3');
      expect(parts.evalBest, '+2.2');
    });

    test('handles mate scores on both sides of the arc', () {
      final parts = parseTacticsNote('Kg2 #3 → +1.2, Qh7+ #3')!;
      expect(parts.playedSan, 'Kg2');
      expect(parts.evalAfter, '+1.2');
      expect(parts.bestSan, 'Qh7+');
      expect(parts.evalBest, '#3');
    });

    test('is null for prose and scraped comments', () {
      expect(parseTacticsNote('Loses the exchange.'), isNull);
      expect(parseTacticsNote(''), isNull);
      expect(
        parseTacticsNote('Remember the knight fork on e7 in this structure.'),
        isNull,
      );
    });
  });
}
