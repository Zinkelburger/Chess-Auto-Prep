import 'package:chess_auto_prep/widgets/tactics/tactics_training_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('displayTacticsNote', () {
    test('rewrites legacy percent notes to terse evals', () {
      // The pre-July-2026 import format. filterDisplayComment's
      // classification stripper used to eat "Blunder. … 69." and show
      // "2% to 48.9% …"; the evals are recovered by inverting the Lichess
      // win-chance formula (69.2% ≈ +2.2, 48.9% ≈ -0.1).
      const legacy = 'Blunder. Win chance dropped from 69.2% to 48.9% '
          '(0.4%). Best was Qf3.';
      expect(displayTacticsNote(legacy), '+2.2 → -0.1, Qf3 +2.2');
    });

    test('legacy percent rewrite saturates extreme win chances at ±10', () {
      const legacy = 'Inaccuracy. Win chance dropped from 100.0% to 90.5% '
          '(-0.2%). Best was Rxe8.';
      expect(displayTacticsNote(legacy), '+10.0 → +6.1, Rxe8 +10.0');
    });

    test('rewrites the short-lived verbose eval format to terse', () {
      const verbose = 'Blunder: h5 dropped your eval from +0.5 to -2.1 '
          '(win chance 55% → 21%). Best was Qf3.';
      expect(displayTacticsNote(verbose), 'h5 +0.5 → -2.1, Qf3 +0.5');
    });

    test('current terse format passes through untouched', () {
      const note = 'h5 +0.5 → -2.1, Qf3 +0.5';
      expect(displayTacticsNote(note), note);
    });

    test('mate scores in the terse format pass through untouched', () {
      const note = 'Kg2 #3 → +1.2, Qh7+ #3';
      expect(displayTacticsNote(note), note);
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
}
