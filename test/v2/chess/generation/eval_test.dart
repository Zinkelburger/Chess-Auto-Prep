import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('U is the logistic curve the whole product agrees on', () {
    // The one number every other implementation of this search is checked
    // against: a pawn up is worth just under 0.6 of a point.
    expect(expectedScore(const Eval(100)), closeTo(0.591026, 1e-6));
    expect(expectedScore(const Eval(-100)), closeTo(0.408974, 1e-6));
    expect(expectedScore(const Eval(300)), closeTo(0.751126, 1e-6));
  });

  test('an equal position is half a point', () {
    expect(expectedScore(const Eval(0)), 0.5);
  });

  test('a score is symmetric about zero', () {
    expect(
      expectedScore(const Eval(250)) + expectedScore(const Eval(-250)),
      closeTo(1, 1e-12),
    );
  });

  test('the curve runs up to the saturation point and then stops', () {
    // 9000 is still a number of centipawns, so it is still on the curve;
    // anything past it is a mate and the game is already decided.
    expect(expectedScore(const Eval(9000)), lessThan(1));
    expect(expectedScore(const Eval(9001)), 1);
    expect(expectedScore(const Eval(-9000)), greaterThan(0));
    expect(expectedScore(const Eval(-9001)), 0);
    expect(expectedScore(const Eval(mateBaseCp)), 1);
    expect(expectedScore(const Eval(-mateBaseCp)), 0);
  });

  test('a score is read from the repertoire side, whoever reported it', () {
    const losingARook = Eval(-500);
    expect(losingARook.forUs(Side.white, Side.white).cp, -500);
    expect(losingARook.forUs(Side.white, Side.black).cp, 500);
    expect(losingARook.forUs(Side.black, Side.black).cp, -500);
    expect(losingARook.forUs(Side.black, Side.white).cp, 500);
  });
}
