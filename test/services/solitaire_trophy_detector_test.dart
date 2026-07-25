import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/solitaire_trophy_detector.dart';

void main() {
  group('trophyAdvantageCp', () {
    // The two inputs use different conventions on purpose: the game move's
    // eval is White-normalized (MoveEval), the user's comes off a raw engine
    // eval of the position after their move and is side-to-move relative.
    test('White guesser: user move leaving +150 beats game move at +30', () {
      // After the user's move it is Black to move and Black is -150, so the
      // engine reports -150 from Black's side.
      expect(
        trophyAdvantageCp(
          gmCpWhiteNorm: 30,
          userCpAfterMove: -150,
          userIsWhite: true,
        ),
        150 - 30,
      );
    });

    test('White guesser: worse move yields a negative advantage', () {
      expect(
        trophyAdvantageCp(
          gmCpWhiteNorm: 200,
          userCpAfterMove: -50,
          userIsWhite: true,
        ),
        50 - 200,
      );
    });

    test('Black guesser: signs flip on both sides', () {
      // Game move left White at -20 (i.e. +20 for Black). The user's move left
      // White at -180 (+180 for Black): White to move, so the engine reports
      // -180 from White's side.
      expect(
        trophyAdvantageCp(
          gmCpWhiteNorm: -20,
          userCpAfterMove: -180,
          userIsWhite: false,
        ),
        180 - 20,
      );
    });

    test('Black guesser: a move helping White scores negative', () {
      expect(
        trophyAdvantageCp(
          gmCpWhiteNorm: -100,
          userCpAfterMove: 40,
          userIsWhite: false,
        ),
        -40 - 100,
      );
    });

    test('equal evals produce no advantage for either side', () {
      expect(
        trophyAdvantageCp(
          gmCpWhiteNorm: 75,
          userCpAfterMove: -75,
          userIsWhite: true,
        ),
        0,
      );
      // Black guesser: the game move left White at -75 (Black +75); matching
      // it means the engine still reports -75 from White's side afterwards.
      expect(
        trophyAdvantageCp(
          gmCpWhiteNorm: -75,
          userCpAfterMove: -75,
          userIsWhite: false,
        ),
        0,
      );
    });
  });

  group('detectSolitaireTrophies', () {
    test('returns nothing without guesses or evals', () async {
      expect(
        await detectSolitaireTrophies(
          guesses: const [],
          evals: const [],
          userIsWhite: true,
          depth: 18,
          gameLabel: '',
          headers: const {},
          pgn: '',
        ),
        isEmpty,
      );
    });
  });
}
