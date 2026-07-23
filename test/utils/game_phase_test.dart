import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/game_phase.dart';

void main() {
  group('classifyGamePhase', () {
    test('starting position is the opening', () {
      expect(
        classifyGamePhase(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        ),
        GamePhase.opening,
      );
    });

    test('developed but full board stays opening until a back rank thins', () {
      // Italian game after a few developing moves: all 14 majors+minors on
      // the board, both back ranks still hold ≥ 4 pieces.
      expect(
        classifyGamePhase(
          'r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
        ),
        GamePhase.opening,
      );
    });

    test('sparse back rank marks the middlegame', () {
      // White's back rank down to 3 pieces (castled, heavy development).
      expect(
        classifyGamePhase(
          'r1bq1rk1/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP1QPPP/R4RK1 w - - 0 8',
        ),
        GamePhase.middlegame,
      );
    });

    test('ten or fewer majors+minors is a middlegame', () {
      // 5 majors+minors per side (one knight traded each, one rook each off).
      expect(
        classifyGamePhase(
          'r1bqk2r/pppp1ppp/2n5/4p3/4P3/2N5/PPPP1PPP/R1BQK2R w KQkq - 0 8',
        ),
        GamePhase.middlegame,
      );
    });

    test('six or fewer majors+minors is the endgame', () {
      // Rook endgame: R+R vs r+r = 4 majors.
      expect(
        classifyGamePhase('8/5pk1/6p1/8/8/6P1/r4PK1/1R6 w - - 0 40'),
        GamePhase.endgame,
      );
      // King and pawn endgame.
      expect(
        classifyGamePhase('8/5pk1/6p1/8/8/6P1/5PK1/8 w - - 0 50'),
        GamePhase.endgame,
      );
    });

    test('malformed FEN falls back to middlegame', () {
      expect(classifyGamePhase('not-a-fen'), GamePhase.middlegame);
    });
  });
}
