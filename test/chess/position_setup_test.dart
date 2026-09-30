import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/chess/position_setup.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _whiteKing = Piece(color: Side.white, role: Role.king);
const _blackKing = Piece(color: Side.black, role: Role.king);

void main() {
  test('builds a legal position from an empty board a square at a time', () {
    var setup = Setup.standard.withBoard(Board.empty);
    expect(setup.illegal, IllegalSetupCause.empty);
    setup = setup.withPiece(Square.e1, _whiteKing);
    expect(setup.illegal, IllegalSetupCause.kings);
    setup = setup
        .withPiece(Square.e8, _blackKing)
        .withMove(Square.e8, Square.d8)
        .withTurn(Side.black);
    expect(setup.illegal, isNull);
    expect(setup.fen, '3k4/8/8/8/8/8/8/4K3 b - - 0 1');
  });

  test('a castling right goes with its rook and is offered only at home', () {
    final start = Setup.standard;
    expect(start.canCastle(Square.h1), isTrue);
    final moved = start.withPiece(Square.h1, null);
    expect(moved.canCastle(Square.h1), isFalse);
    expect(moved.fen.split(' ')[2], 'Qkq');
    expect(start.withCastling(Square.a8, on: false).fen.split(' ')[2], 'KQk');
    // Asking for a right the board cannot give changes nothing.
    expect(moved.withCastling(Square.h1, on: true).fen, moved.fen);
  });

  test('en passant is offered behind a pawn that could have come two', () {
    final setup = SetupEdits.read('4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1')!;
    expect(setup.enPassantSquares, [Square.d6]);
    final passed = setup.withEnPassant(Square.d6);
    expect(passed.fen, '4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1');
    // Black to move now: the square is gone with the turn.
    expect(passed.withTurn(Side.black).epSquare, isNull);
    expect(setup.withEnPassant(Square.a6).epSquare, isNull);
  });

  test('reads a FEN with missing fields; text that is none is null', () {
    expect(
      SetupEdits.read('8/8/4k3/8/8/4K3/4R3/8')?.fen,
      '8/8/4k3/8/8/4K3/4R3/8 w - - 0 1',
    );
    expect(SetupEdits.read('8/8/8 w'), isNull);
    expect(SetupEdits.read(''), isNull);
    // dartchess's board parser throws a bare ArgumentError on this one.
    const stray = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/.NBQKBNR w KQkq - 0 1';
    expect(SetupEdits.read(stray), isNull);
    expect(readSetup(stray), isNull);
    expect(positionOf(const Fen(stray)), isNull);
    expect(playableFen(stray), isNull);
  });

  test('en passant needs a pawn that can take: the FEN is the one moves '
      'reach', () {
    final byMoves = Chess.initial.play(Move.parse('e2e4')!);
    const typed = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
    final setup = SetupEdits.read(typed)!;
    expect(setup.enPassantSquares, isEmpty);
    expect(setup.asFen, Fen(byMoves.fen));
    expect(playableFen(typed), Fen(byMoves.fen));

    // 1.e4 d5 2.e5 f5: exf6 is legal, so moves write f6 and so does the
    // editor.
    Position played = Chess.initial;
    for (final uci in ['e2e4', 'd7d5', 'e4e5', 'f7f5']) {
      played = played.play(Move.parse(uci)!);
    }
    expect(played.fen.split(' ')[3], 'f6');
    expect(SetupEdits.read(played.fen)!.asFen, Fen(played.fen));

    // With a black pawn beside it, e3 can be taken and stays.
    const takeable = '4k3/8/8/8/3pP3/8/8/4K3 b - e3 0 1';
    expect(SetupEdits.read(takeable)!.enPassantSquares, [Square.e3]);
    expect(SetupEdits.read(takeable)!.fen, takeable);

    // Taking would leave the king in check along the rank: no square.
    const pinned = '4k3/8/8/K2pP2r/8/8/8/8 w - d6 0 1';
    final legal = Chess.fromSetup(Setup.parseFen(pinned));
    expect(legal.fen.split(' ')[3], '-');
    expect(SetupEdits.read(pinned)!.enPassantSquares, isEmpty);
    expect(SetupEdits.read(pinned)!.asFen, Fen(legal.fen));
  });

  test('playableFen answers only a FEN a game could start from', () {
    expect(playableFen(Fen.initial.value), Fen.initial);
    expect(playableFen('8/8/8/8/8/8/8/8 w - - 0 1'), isNull);
    expect(playableFen('4k3/4Q3/4K3/8/8/8/8/8 w - - 0 1'), isNull);
  });
}
