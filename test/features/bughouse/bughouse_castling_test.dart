import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Castling, and the invariant it used to break.
///
/// dartchess encodes castling as king-takes-own-rook, so the move's
/// destination square holds one of *our* pieces. [BughouseState.playMove]
/// reads that square to find what a move captured, which meant every castle
/// looked like a capture of our own rook: the rook was handed to the partner
/// board, and the matching decrement of a pocket that had never held it
/// corrupted the counts outright — reserves came back holding dozens of
/// queens, and kings, which no legal position can produce.
void main() {
  test('all castling rights can be restored after disabling them', () {
    for (final side in Side.values) {
      for (final flank in CastlingSide.values) {
        final disabled = BughouseState.initial().withCastlingRight(
          BughouseBoard.a,
          side,
          flank,
          false,
        )!;
        expect(disabled.boardA.castles.rookOf(side, flank), isNull);
        final enabled = disabled.withCastlingRight(
          BughouseBoard.a,
          side,
          flank,
          true,
        );
        expect(enabled, isNotNull);
        expect(enabled!.boardA.castles.rookOf(side, flank), isNotNull);
      }
    }
    expect(
      BughouseState.empty().withCastlingRight(
        BughouseBoard.a,
        Side.white,
        CastlingSide.king,
        true,
      ),
      isNull,
    );
  });

  /// Total pieces anywhere: on either board, or in any of the four reserves.
  /// Bughouse never creates or destroys material, so this is 64 for ever.
  int material(BughouseState state) {
    var total = 0;
    for (final which in BughouseBoard.values) {
      final position = state.board(which);
      total += position.board.occupied.size;
      final pockets = position.pockets ?? Pockets.empty;
      for (final side in Side.values) {
        for (final role in Role.values) {
          total += pockets.of(side, role);
        }
      }
    }
    return total;
  }

  /// White to move with the king's side cleared for castling on board A.
  BughouseState readyToCastle() {
    final position = Crazyhouse.fromSetup(
      Setup.parseFen(
        'rnbqk2r/pppppppp/5n2/8/8/5N2/PPPPPPPP/RNBQK2R[] w KQkq - 0 1',
      ),
      ignoreImpossibleCheck: true,
    );
    return BughouseState.initial().withBoard(BughouseBoard.a, position);
  }

  group('castling is not a capture', () {
    test('castling leaves every reserve empty', () {
      final before = readyToCastle();
      final move = before.board(BughouseBoard.a).parseSan('O-O');
      expect(move, isNotNull);

      final after = before.playMove(BughouseBoard.a, move!);
      expect(after, isNotNull);

      for (final which in BughouseBoard.values) {
        final pockets = after!.board(which).pockets ?? Pockets.empty;
        for (final side in Side.values) {
          for (final role in Role.values) {
            expect(
              pockets.of(side, role),
              0,
              reason: 'castling put a ${role.name} in ${which.name}\'s reserve',
            );
          }
        }
      }
    });

    test('castling conserves material', () {
      final before = readyToCastle();
      final move = before.board(BughouseBoard.a).parseSan('O-O')!;
      final after = before.playMove(BughouseBoard.a, move)!;
      expect(material(after), material(before));
    });

    test('the rook is still on the board, not in a pocket', () {
      final before = readyToCastle();
      final move = before.board(BughouseBoard.a).parseSan('O-O')!;
      final after = before.playMove(BughouseBoard.a, move)!;
      final board = after.board(BughouseBoard.a).board;
      expect(
        board.pieceAt(Square.f1),
        const Piece(color: Side.white, role: Role.rook),
      );
      expect(
        board.pieceAt(Square.g1),
        const Piece(color: Side.white, role: Role.king),
      );
    });

    test('queenside castling is not a capture either', () {
      final position = Crazyhouse.fromSetup(
        Setup.parseFen(
          'r3kbnr/pppppppp/2nq1b2/8/8/2NQ1B2/PPPPPPPP/R3KBNR[] w KQkq - 0 1',
        ),
        ignoreImpossibleCheck: true,
      );
      final before = BughouseState.initial().withBoard(
        BughouseBoard.a,
        position,
      );
      final move = before.board(BughouseBoard.a).parseSan('O-O-O')!;
      final after = before.playMove(BughouseBoard.a, move)!;
      expect(material(after), material(before));
      final pockets = after.board(BughouseBoard.b).pockets ?? Pockets.empty;
      expect(pockets.of(Side.white, Role.rook), 0);
    });
  });

  group('a real capture still crosses to the partner board', () {
    test('a captured piece keeps its colour and changes board', () {
      // Black knight on f6 takes a white pawn on e4: the white pawn goes to
      // board B's reserve as a *white* pawn, because our partner sits there
      // playing the colour we are taking from.
      final position = Crazyhouse.fromSetup(
        Setup.parseFen(
          'rnbqkb1r/pppp1ppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 1',
        ),
        ignoreImpossibleCheck: true,
      );
      final before = BughouseState.initial().withBoard(
        BughouseBoard.a,
        position,
      );
      final move = before.board(BughouseBoard.a).parseSan('Nxe4')!;
      final after = before.playMove(BughouseBoard.a, move)!;

      expect(material(after), material(before));
      final partner = after.board(BughouseBoard.b).pockets ?? Pockets.empty;
      expect(partner.of(Side.white, Role.pawn), 1);
      final own = after.board(BughouseBoard.a).pockets ?? Pockets.empty;
      expect(own.of(Side.black, Role.pawn), 0, reason: 'stayed on our board');
    });
  });
}
