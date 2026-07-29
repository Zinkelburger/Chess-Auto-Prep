import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/game_analysis_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fool's mate: Black mates on move 2. The mating move must never be
  // classified from an engine score — a mated position has no search result
  // and a mate-0 score has no sign, which used to flag the winner's mating
  // move as a blunder.
  const foolsMate =
      '[Event "Test"]\n'
      '[White "A"]\n'
      '[Black "B"]\n'
      '[Result "0-1"]\n'
      '\n'
      '1. f3 { [%eval 0.00,18] } e5 { [%eval -0.5,18] } '
      '2. g4 { [%eval -6.0,18] } Qh4# 0-1\n';

  // Same game, but a previous (buggy) analysis stored a sign-ambiguous
  // mate-0 eval on the mating move. The board fact must win over the
  // stored comment.
  const foolsMateWithBogusEval =
      '[Event "Test"]\n'
      '[White "A"]\n'
      '[Black "B"]\n'
      '[Result "0-1"]\n'
      '\n'
      '1. f3 { [%eval 0.00,18] } e5 { [%eval -0.5,18] } '
      '2. g4 { [%eval -6.0,18] } Qh4# { [%eval #0,18] } 0-1\n';

  group('cached-eval restore around checkmate', () {
    for (final (label, pgn) in [
      ('without stored eval on the mating move', foolsMate),
      ('with a stale mate-0 eval on the mating move', foolsMateWithBogusEval),
    ]) {
      test('mating move is synthesized from the board $label', () async {
        final controller = GameAnalysisController();
        addTearDown(controller.dispose);

        final loaded = await controller.tryLoadFromPgn(pgn);
        expect(loaded, isTrue);
        expect(controller.evals, hasLength(4));

        final mate = controller.evals.last;
        expect(mate.san, 'Qh4#');
        expect(mate.deliversCheckmate, isTrue);
        // Black delivered mate: White-normalized winning chance is exactly -1
        // and there is no engine score to misread.
        expect(mate.winningChance, -1.0);
        expect(mate.scoreCp, isNull);
        expect(mate.scoreMate, isNull);
        expect(mate.effectiveCp, isNegative);
        // The winner's mating move is not a blunder/mistake/inaccuracy.
        expect(
          mate.classification,
          isNot(
            isIn([
              MoveClassification.blunder,
              MoveClassification.mistake,
              MoveClassification.inaccuracy,
            ]),
          ),
        );
      });
    }

    test('the loser\'s losing move is still classified', () async {
      final controller = GameAnalysisController();
      addTearDown(controller.dispose);

      await controller.tryLoadFromPgn(foolsMate);
      // 2. g4 (0.00-ish → -6.0) is White's losing lunge and must still be
      // flagged; synthesizing the mate ply must not defuse earlier moves.
      final g4 = controller.evals.firstWhere((e) => e.san == 'g4');
      expect(g4.classification, MoveClassification.blunder);
    });
  });
}
