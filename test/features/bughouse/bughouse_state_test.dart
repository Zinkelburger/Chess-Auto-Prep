import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BughouseJointMove', () {
    test('parses a move plus a pass', () {
      final move = BughouseJointMove.tryParse('(d2d4,pass)');
      expect(move, isNotNull);
      expect(move!.a.uci, 'd2d4');
      expect(move.a.isPass, isFalse);
      expect(move.b.isPass, isTrue);
      expect(move.toString(), '(d2d4,pass)');
    });

    test('parses a move on both boards', () {
      final move = BughouseJointMove.tryParse('(d7d5,e2e4)')!;
      expect(move.a.uci, 'd7d5');
      expect(move.b.uci, 'e2e4');
      expect(move.isEmpty, isFalse);
    });

    test('treats a double pass as empty', () {
      expect(BughouseJointMove.tryParse('(pass,pass)')!.isEmpty, isTrue);
    });

    test('rejects anything that is not a joint move', () {
      expect(BughouseJointMove.tryParse('d2d4'), isNull);
      expect(BughouseJointMove.tryParse('(d2d4)'), isNull);
      expect(BughouseJointMove.tryParse(''), isNull);
    });
  });

  group('BughouseState', () {
    test('a team plays opposite colours on the two boards', () {
      final state = BughouseState.initial();
      expect(state.sideOn(BughouseBoard.a), Side.white);
      expect(state.sideOn(BughouseBoard.b), Side.black);

      final black = state.copyWith(team: Side.black);
      expect(black.sideOn(BughouseBoard.a), Side.black);
      expect(black.sideOn(BughouseBoard.b), Side.white);
    });

    test('at the start only board A is on turn for a white team', () {
      final state = BughouseState.initial();
      // Both boards open with white to move, but the team is black on board B,
      // so it owes a move on A only.
      expect(state.isOurTurn(BughouseBoard.a), isTrue);
      expect(state.isOurTurn(BughouseBoard.b), isFalse);
    });

    test('dual FEN joins both boards with a pipe', () {
      final fen = BughouseState.initial().dualFen;
      expect(fen.split('|'), hasLength(2));
      // Crazyhouse FENs carry the pocket, which is what makes them bughouse
      // positions rather than chess ones.
      expect(fen, contains('[]'));
    });

    test('boards advance independently', () {
      var state = BughouseState.initial();
      const move = NormalMove(from: Square.e2, to: Square.e4);
      state = state.withBoard(
        BughouseBoard.a,
        state.boardA.playUnchecked(move) as Crazyhouse,
      );
      expect(state.boardA.turn, Side.black);
      expect(state.boardB.turn, Side.white, reason: 'board B untouched');
    });
  });

  group('BughouseBoard', () {
    test('carries the digit the engine prefixes moves with', () {
      expect(BughouseBoard.a.uciPrefix, '1');
      expect(BughouseBoard.b.uciPrefix, '2');
    });
  });
}
