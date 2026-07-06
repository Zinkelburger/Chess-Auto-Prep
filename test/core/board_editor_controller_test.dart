import 'package:chess_auto_prep/core/board_editor_controller.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FEN round-trip', () {
    test('starts at the standard position', () {
      final c = BoardEditorController();
      expect(c.fen, Chess.initial.fen);
      expect(c.validPosition, isNotNull);
    });

    test('loadFen round-trips a full 6-field FEN', () {
      const fen = 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 1';
      final c = BoardEditorController();
      expect(c.loadFen(fen), isTrue);
      expect(c.fen, fen);
    });

    test('loadFen accepts a 4-field FEN and pads the counters', () {
      final c = BoardEditorController();
      expect(c.loadFen('4k3/8/8/8/8/8/8/4K3 b - -'), isTrue);
      expect(c.fen, '4k3/8/8/8/8/8/8/4K3 b - - 0 1');
      expect(c.turn, Side.black);
    });

    test('invalid FEN is rejected and editor state is untouched', () {
      final c = BoardEditorController();
      final before = c.fen;
      expect(c.loadFen('not a fen'), isFalse);
      expect(c.fen, before);
    });

    test('constructor seeds from initialFen', () {
      const fen = '4k3/8/8/8/8/8/8/4K2R w K - 0 1';
      final c = BoardEditorController(initialFen: fen);
      expect(c.fen, fen);
    });
  });

  group('piece placement', () {
    test('set, move, and remove pieces', () {
      final c = BoardEditorController();
      c.clear();
      c.setPiece(Square.e4, const Piece(color: Side.white, role: Role.queen));
      expect(c.pieceAt(Square.e4)?.role, Role.queen);

      c.movePiece(Square.e4, Square.d5);
      expect(c.pieceAt(Square.e4), isNull);
      expect(c.pieceAt(Square.d5)?.role, Role.queen);

      c.removePiece(Square.d5);
      expect(c.pieceAt(Square.d5), isNull);
    });

    test('tapSquare with brush places, tap-again removes', () {
      final c = BoardEditorController();
      c.clear();
      const knight = Piece(color: Side.black, role: Role.knight);
      c.selectTool(const PieceBrush(knight));

      c.tapSquare(Square.c3);
      expect(c.pieceAt(Square.c3), knight);

      c.tapSquare(Square.c3);
      expect(c.pieceAt(Square.c3), isNull);
    });

    test('eraser removes pieces on tap', () {
      final c = BoardEditorController();
      c.selectTool(const EraserTool());
      c.tapSquare(Square.e2);
      expect(c.pieceAt(Square.e2), isNull);
    });
  });

  group('castling clamp', () {
    test('rights are clamped when the rook leaves its home square', () {
      final c = BoardEditorController();
      expect(c.whiteKingside, isTrue);

      c.movePiece(Square.h1, Square.h4);
      expect(c.whiteKingsideAllowed, isFalse);
      expect(c.whiteKingside, isFalse);
      // Other rights untouched.
      expect(c.whiteQueenside, isTrue);
      expect(c.blackKingside, isTrue);

      // Desire is preserved: putting the rook back restores the right.
      c.movePiece(Square.h4, Square.h1);
      expect(c.whiteKingside, isTrue);
    });

    test('rights are clamped when the king moves', () {
      final c = BoardEditorController();
      c.movePiece(Square.e8, Square.d8);
      expect(c.blackKingside, isFalse);
      expect(c.blackQueenside, isFalse);
      expect(c.whiteKingside, isTrue);
    });

    test('clamped rights never reach the FEN', () {
      final c = BoardEditorController();
      c.movePiece(Square.a1, Square.a3);
      expect(c.fen.split(' ')[2], 'Kkq');
    });
  });

  group('en passant candidates', () {
    test('white to move: candidate on rank 6 behind a black pawn', () {
      final c = BoardEditorController();
      // Simulate 1. e4 e6 2. e5 d5 → black pawn on d5, ep target d6.
      c.loadFen(
          'rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 3');
      expect(c.epCandidates, contains(Square.d6));
      expect(c.epCandidates, isNot(contains(Square.e6))); // e-pawn is ours

      c.setEpSquare(Square.d6);
      expect(c.fen.split(' ')[3], 'd6');
    });

    test('black to move: candidate on rank 3 behind a white pawn', () {
      final c = BoardEditorController();
      c.loadFen(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1');
      expect(c.epCandidates, contains(Square.e3));
    });

    test('no candidate when the origin square is occupied', () {
      final c = BoardEditorController();
      // Black pawn on d5 but another piece on d7 → d7–d5 was impossible.
      c.loadFen(
          'rnbqkbnr/pppn1ppp/8/3pP3/8/8/PPPP1PPP/RNBQKB1R w KQkq - 0 3');
      expect(c.epCandidates, isNot(contains(Square.d6)));
    });

    test('ep square is cleared when the board change invalidates it', () {
      final c = BoardEditorController();
      c.loadFen(
          'rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3');
      expect(c.epSquare, Square.d6);

      c.removePiece(Square.d5); // the pawn that could be captured
      expect(c.epSquare, isNull);
    });

    test('ep square is cleared when the turn changes', () {
      final c = BoardEditorController();
      c.loadFen(
          'rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3');
      expect(c.epSquare, Square.d6);
      c.setTurn(Side.black);
      expect(c.epSquare, isNull);
    });

    test('setEpSquare rejects non-candidates', () {
      final c = BoardEditorController();
      c.setEpSquare(Square.e6);
      expect(c.epSquare, isNull);
    });
  });

  group('validation', () {
    test('empty board is invalid', () {
      final c = BoardEditorController();
      c.clear();
      expect(c.validPosition, isNull);
      expect(c.validationError, contains('empty'));
    });

    test('missing king is invalid', () {
      final c = BoardEditorController();
      c.clear();
      c.setPiece(Square.e1, const Piece(color: Side.white, role: Role.king));
      c.setPiece(Square.e4, const Piece(color: Side.black, role: Role.queen));
      expect(c.validPosition, isNull);
      expect(c.validationError, contains('king'));
    });

    test('pawn on the back rank is invalid', () {
      final c = BoardEditorController();
      c.clear();
      c.setPiece(Square.e1, const Piece(color: Side.white, role: Role.king));
      c.setPiece(Square.e8, const Piece(color: Side.black, role: Role.king));
      c.setPiece(Square.a8, const Piece(color: Side.white, role: Role.pawn));
      expect(c.validPosition, isNull);
      expect(c.validationError, contains('Pawns'));
    });

    test('side not to move in check is invalid', () {
      final c = BoardEditorController();
      c.clear();
      c.setPiece(Square.e1, const Piece(color: Side.white, role: Role.king));
      c.setPiece(Square.e8, const Piece(color: Side.black, role: Role.king));
      c.setPiece(Square.e4, const Piece(color: Side.white, role: Role.rook));
      // White to move but Black (not to move) is in check from the e4 rook.
      expect(c.validPosition, isNull);
      expect(c.validationError, contains('not to move'));
    });

    test('a legal custom setup validates', () {
      final c = BoardEditorController();
      c.clear();
      c.setPiece(Square.e1, const Piece(color: Side.white, role: Role.king));
      c.setPiece(Square.e8, const Piece(color: Side.black, role: Role.king));
      c.setPiece(Square.d1, const Piece(color: Side.white, role: Role.queen));
      final position = c.validPosition;
      expect(position, isNotNull);
      expect(position!.turn, Side.white);
    });
  });
}
