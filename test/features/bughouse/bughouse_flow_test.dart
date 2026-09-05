import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// The defining rule of bughouse, and the one a crazyhouse library gets
/// backwards: a captured piece keeps its colour and moves to the *other*
/// board, because you hand it to a partner who plays the opposite colour.
void main() {
  group('cross-board piece flow', () {
    test('a capture feeds the other board, colour intact', () {
      // 1.e4 d5 2.exd5 — white captures a black pawn on board A.
      var state = BughouseState.initial();
      for (final move in [
        const NormalMove(from: Square.e2, to: Square.e4),
        const NormalMove(from: Square.d7, to: Square.d5),
        const NormalMove(from: Square.e4, to: Square.d5),
      ]) {
        state = state.playMove(BughouseBoard.a, move)!;
      }

      // Crazyhouse would have given White a white pawn on this board.
      expect(
        state.boardA.pockets!.of(Side.white, Role.pawn),
        0,
        reason: 'the capturing board keeps nothing',
      );
      expect(
        state.boardA.pockets!.of(Side.black, Role.pawn),
        0,
        reason: 'and it does not land on board A at all',
      );
      // Bughouse gives the partner a *black* pawn on board B.
      expect(state.boardB.pockets!.of(Side.black, Role.pawn), 1);
      expect(state.boardB.pockets!.of(Side.white, Role.pawn), 0);
    });

    test('a capture on board B feeds board A', () {
      var state = BughouseState.initial();
      for (final move in [
        const NormalMove(from: Square.d2, to: Square.d4),
        const NormalMove(from: Square.e7, to: Square.e5),
        const NormalMove(from: Square.d4, to: Square.e5),
      ]) {
        state = state.playMove(BughouseBoard.b, move)!;
      }
      expect(state.boardA.pockets!.of(Side.black, Role.pawn), 1);
      expect(state.boardB.pockets!.size, 0);
    });

    test('a captured promoted piece arrives as a pawn', () {
      // Black queen on a1 is a promoted pawn; white rook takes it.
      const fen = '4k3/8/8/8/8/q7/8/R3K3[] w - - 0 1';
      var state = BughouseState.tryParseDualFen('$fen|$fen')!;
      // Mark the queen as promoted, the way a real promotion would have.
      final promoted = state.boardA.board.promoted.withSquare(Square.a3);
      state = state.withBoard(
        BughouseBoard.a,
        state.boardA.copyWith(board: state.boardA.board.withPromoted(promoted))
            as Crazyhouse,
      );

      final after = state.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.a1, to: Square.a3),
      );
      expect(after, isNotNull, reason: 'Rxa3 is legal');
      expect(
        after!.boardB.pockets!.of(Side.black, Role.queen),
        0,
        reason: 'a promoted queen reverts',
      );
      expect(after.boardB.pockets!.of(Side.black, Role.pawn), 1);
    });

    test('en passant routes the pawn it actually takes', () {
      // White pawn e5, black plays d7-d5, white takes en passant.
      var state = BughouseState.tryParseDualFen(
        '4k3/3p4/8/4P3/8/8/8/4K3[] b - - 0 1|4k3/8/8/8/8/8/8/4K3[] w - - 0 1',
      )!;
      state = state.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.d7, to: Square.d5),
      )!;
      final after = state.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e5, to: Square.d6),
      );
      expect(after, isNotNull, reason: 'exd6 e.p. is legal');
      expect(after!.boardB.pockets!.of(Side.black, Role.pawn), 1);
      expect(after.boardA.board.pieceAt(Square.d5), isNull);
    });

    test('a quiet move feeds nobody', () {
      final state = BughouseState.initial().playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e2, to: Square.e4),
      )!;
      expect(state.boardA.pockets!.size, 0);
      expect(state.boardB.pockets!.size, 0);
    });

    test('an illegal move is refused rather than applied', () {
      final state = BughouseState.initial();
      expect(
        state.playMove(
          BughouseBoard.a,
          const NormalMove(from: Square.e2, to: Square.e5),
        ),
        isNull,
      );
    });
  });

  group('drops', () {
    test('a fed piece can be dropped on the board that received it', () {
      var state = BughouseState.initial();
      for (final move in [
        const NormalMove(from: Square.e2, to: Square.e4),
        const NormalMove(from: Square.d7, to: Square.d5),
        const NormalMove(from: Square.e4, to: Square.d5),
      ]) {
        state = state.playMove(BughouseBoard.a, move)!;
      }
      // Board B: black now holds a pawn. Give black the move and drop it.
      state = state.withTurn(BughouseBoard.b, Side.black);
      final dropped = state.playMove(
        BughouseBoard.b,
        const DropMove(to: Square.e6, role: Role.pawn),
      );
      expect(dropped, isNotNull);
      expect(
        dropped!.boardB.board.pieceAt(Square.e6),
        const Piece(color: Side.black, role: Role.pawn),
      );
      expect(dropped.boardB.pockets!.of(Side.black, Role.pawn), 0);
    });

    test('a piece cannot be dropped on the board that captured it', () {
      var state = BughouseState.initial();
      for (final move in [
        const NormalMove(from: Square.e2, to: Square.e4),
        const NormalMove(from: Square.d7, to: Square.d5),
        const NormalMove(from: Square.e4, to: Square.d5),
      ]) {
        state = state.playMove(BughouseBoard.a, move)!;
      }
      state = state.withTurn(BughouseBoard.a, Side.black);
      expect(
        state.playMove(
          BughouseBoard.a,
          const DropMove(to: Square.e6, role: Role.pawn),
        ),
        isNull,
        reason: 'board A never received the pawn',
      );
    });
  });

  group('editing', () {
    test('pockets can be edited directly and never go below zero', () {
      var state = BughouseState.initial();
      state = state.withPocket(BughouseBoard.a, Side.white, Role.queen, 2);
      expect(state.boardA.pockets!.of(Side.white, Role.queen), 2);
      state = state.withPocket(BughouseBoard.a, Side.white, Role.queen, -5);
      expect(state.boardA.pockets!.of(Side.white, Role.queen), 0);
    });

    test('a piece can be placed and erased', () {
      var state = BughouseState.empty();
      // "Empty" keeps the two kings: a board with none cannot be represented.
      expect(state.boardA.board.occupied.size, 2);
      state = state.withPieceAt(
        BughouseBoard.a,
        Square.e4,
        const Piece(color: Side.white, role: Role.knight),
      )!;
      expect(state.boardA.board.pieceAt(Square.e4)?.role, Role.knight);
      state = state.withPieceAt(BughouseBoard.a, Square.e4, null)!;
      expect(state.boardA.board.pieceAt(Square.e4), isNull);
    });

    test('side to move is settable per board', () {
      final state = BughouseState.initial().withTurn(
        BughouseBoard.b,
        Side.black,
      );
      expect(state.boardA.turn, Side.white);
      expect(state.boardB.turn, Side.black);
    });

    test('a dual FEN round-trips', () {
      final original = BughouseState.initial().playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e2, to: Square.e4),
      )!;
      final reparsed = BughouseState.tryParseDualFen(original.dualFen);
      expect(reparsed, isNotNull);
      expect(reparsed!.dualFen, original.dualFen);
    });

    test('a single FEN means board A, and leaves board B at the start', () {
      // The same reading the MCP server gives it. The two used to disagree —
      // this side copied the FEN onto both boards — so one string pasted into
      // the app and handed to `mcp__bughouse__analyse` produced two different
      // positions.
      const boardA =
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 1';
      final state = BughouseState.tryParseDualFen(boardA);
      expect(state, isNotNull);
      expect(state!.boardA.fen, boardA);
      expect(state.boardB.fen, Crazyhouse.initial.fen);
    });

    test('nonsense FEN is rejected, not thrown', () {
      expect(BughouseState.tryParseDualFen('not a fen'), isNull);
      expect(BughouseState.tryParseDualFen('a|b|c'), isNull);
      expect(BughouseState.tryParseDualFen(''), isNull);
    });
  });

  group('clocks and stance', () {
    test('mixed diagonals cannot buy sitting with a partners surplus', () {
      const clocks = BughouseClocks(
        whiteA: Duration(seconds: 10),
        blackB: Duration(seconds: 300),
        blackA: Duration(seconds: 100),
        whiteB: Duration(seconds: 100),
      );
      expect(clocks.stanceFor(Side.white), BughouseTimeStance.level);
      expect(clocks.stanceFor(Side.black), BughouseTimeStance.level);
    });

    test('stance is the diagonal comparison', () {
      const lopsided = BughouseClocks(
        whiteA: Duration(seconds: 60),
        blackA: Duration(seconds: 120),
        whiteB: Duration(seconds: 120),
        blackB: Duration(seconds: 60),
      );
      // White's team is white-on-A plus black-on-B: 60 + 60 = 120.
      // Their opponents: 120 + 120 = 240.
      expect(lopsided.stanceFor(Side.white), BughouseTimeStance.behind);
      expect(lopsided.stanceFor(Side.black), BughouseTimeStance.ahead);
    });

    test('a near-equal clock reads as level, not a coin flip', () {
      const almost = BughouseClocks(
        whiteA: Duration(seconds: 121),
        blackA: Duration(seconds: 120),
        whiteB: Duration(seconds: 120),
        blackB: Duration(seconds: 120),
      );
      expect(almost.stanceFor(Side.white), BughouseTimeStance.level);
      expect(almost.stanceFor(Side.black), BughouseTimeStance.level);
    });

    test('the clock answers for both teams at once', () {
      // One diagonal, two teams: if we are behind, the people we are playing
      // are the ones allowed to sit, and their search has to be told so.
      final behind = BughouseState.initial().copyWith(
        timeStance: BughouseTimeStance.behind,
      );
      expect(behind.timeAdvantageFor(Side.white), isFalse);
      expect(behind.timeAdvantageFor(Side.black), isTrue);

      final ahead = behind.copyWith(timeStance: BughouseTimeStance.ahead);
      expect(ahead.timeAdvantageFor(Side.white), isTrue);
      expect(ahead.timeAdvantageFor(Side.black), isFalse);

      final level = behind.copyWith(timeStance: BughouseTimeStance.level);
      expect(level.timeAdvantageFor(Side.white), isFalse);
      expect(level.timeAdvantageFor(Side.black), isFalse);
    });

    test('the four players are lettered, and the boards numbered', () {
      // One alphabet per thing being named: boards are 1 and 2, players are
      // A and B facing each other on board 1, C and D on board 2.
      final state = BughouseState.initial();
      expect(BughouseBoard.a.label, 'Board 1');
      expect(BughouseBoard.b.label, 'Board 2');
      expect(state.seatLetter(BughouseBoard.a, Side.white), 'A');
      expect(state.seatLetter(BughouseBoard.a, Side.black), 'B');
      expect(state.seatLetter(BughouseBoard.b, Side.black), 'C');
      expect(state.seatLetter(BughouseBoard.b, Side.white), 'D');
      expect(state.teamLetters(Side.white), 'A + C');
      expect(state.teamLetters(Side.black), 'B + D');
      expect(
        state.seatDescription(BughouseBoard.b, Side.white),
        'D — your partner\'s opponent, white on board 2',
      );

      // Playing the other colour moves the letters with us, because they name
      // seats at the table rather than colours.
      final flipped = state.copyWith(team: Side.black);
      expect(flipped.seatLetter(BughouseBoard.a, Side.black), 'A');
      expect(flipped.seatLetter(BughouseBoard.b, Side.white), 'C');
    });

    test('only "ahead" unlocks sitting for the engine', () {
      // The engine's clock model is one bit, so level and behind collapse.
      expect(BughouseTimeStance.ahead.givesTimeAdvantage, isTrue);
      expect(BughouseTimeStance.level.givesTimeAdvantage, isFalse);
      expect(BughouseTimeStance.behind.givesTimeAdvantage, isFalse);

      const level = BughouseState(
        boardA: Crazyhouse.initial,
        boardB: Crazyhouse.initial,
        timeStance: BughouseTimeStance.level,
      );
      expect(level.teamHasTimeAdvantage, isFalse);
      expect(
        level
            .copyWith(timeStance: BughouseTimeStance.ahead)
            .teamHasTimeAdvantage,
        isTrue,
      );
    });

    test('RequireMoveOn maps to the engine option values', () {
      expect(RequireMoveOn.none.uciValue, 'none');
      expect(RequireMoveOn.boardA.uciValue, 'A');
      expect(RequireMoveOn.boardB.uciValue, 'B');
    });
  });
}
