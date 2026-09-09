import 'package:chess_auto_prep/services/engine/threat_position.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hypothetical pass flips turn, expires en passant, preserves board', () {
    final position = Chess.initial.play(Move.parse('e2e4')!);
    final threat = Chess.fromSetup(
      Setup.parseFen(threatPositionFen(position.fen)!),
    );
    expect(threat.turn, Side.white);
    expect(threat.board, position.board);
    expect(threat.epSquare, isNull);
    expect(threat.fullmoves, 2);
    expect(threat.castles, position.castles);
  });
  test('cannot pass in check, at game over, or from invalid input', () {
    expect(threatPositionFen('4k3/8/8/8/8/8/4R3/4K3 b - - 0 1'), isNull);
    expect(threatPositionFen('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'), isNull);
    expect(threatPositionFen('invalid'), isNull);
  });
}
