/// Scid's per-side piece list — the thing its move encoding indexes into.
///
/// A Scid move is one byte: the high nibble is the moving piece's slot in the
/// side's piece list, the low nibble a per-piece-type direction code. So an
/// encoder that does not reproduce Scid's list *exactly* writes bytes that
/// decode to different moves a few plies later, silently.
///
/// The rules, read from Scid's `src/position.cpp`:
///
///  * **Standard start** (`StdStart`, :656-675) uses a fixed order per side —
///    `K R N B Q B N R` on the back rank, then the pawns a→h. This is NOT the
///    order the same position would get from a FEN, so the two starts must be
///    kept apart (which is what the game blob's start-board flag does).
///  * **A FEN start** (`AddPiece`, :720-743) appends pieces in FEN read order
///    (rank 8→1, file a→h), except the king, which is forced into slot 0 by
///    moving whatever occupied it to the end.
///  * **A capture** (:1568-1571) is a swap-with-last removal: the last piece
///    in the list takes the captured piece's slot.
///  * **A promotion** (:1520, :1529) keeps the pawn's slot.
///  * **Castling** moves king and rook to their slots, both retained.
library;

import 'package:dartchess/dartchess.dart';

/// Sentinel for "no piece here" in the square→slot map.
const int _noSlot = -1;

/// Mutable mirror of Scid's `List[color][16]` / `ListPos[64]`.
class ScidPieceList {
  ScidPieceList._(this._squares, this._slotOf, this._counts);

  /// `_squares[color][slot]` = square, for slots `< _counts[color]`.
  final List<List<int>> _squares;

  /// `_slotOf[square]` = the slot the piece on that square occupies.
  final List<int> _slotOf;

  /// Live piece count per side.
  final List<int> _counts;

  static const int _white = 0;
  static const int _black = 1;

  static int _side(Side side) => side == Side.white ? _white : _black;

  /// The fixed ordering Scid gives the standard opening position.
  factory ScidPieceList.standard() {
    final squares = [List<int>.filled(16, 0), List<int>.filled(16, 0)];
    final slotOf = List<int>.filled(64, _noSlot);

    // Back-rank order is K, R, N, B, Q, B, N, R — not a1..h1.
    const backRankFiles = [4, 0, 1, 2, 3, 5, 6, 7];
    for (var side = 0; side < 2; side++) {
      final backRank = side == _white ? 0 : 7;
      final pawnRank = side == _white ? 1 : 6;
      for (var slot = 0; slot < 8; slot++) {
        final sq = backRank * 8 + backRankFiles[slot];
        squares[side][slot] = sq;
        slotOf[sq] = slot;
      }
      for (var file = 0; file < 8; file++) {
        final sq = pawnRank * 8 + file;
        squares[side][8 + file] = sq;
        slotOf[sq] = 8 + file;
      }
    }
    return ScidPieceList._(squares, slotOf, [16, 16]);
  }

  /// The ordering Scid gives a position parsed from a FEN: pieces appended in
  /// FEN read order, king forced to slot 0.
  factory ScidPieceList.fromPosition(Position position) {
    final squares = [List<int>.filled(16, 0), List<int>.filled(16, 0)];
    final slotOf = List<int>.filled(64, _noSlot);
    final counts = [0, 0];

    // FEN reads rank 8 down to rank 1, file a to h.
    for (var rank = 7; rank >= 0; rank--) {
      for (var file = 0; file < 8; file++) {
        final sq = rank * 8 + file;
        final piece = position.board.pieceAt(Square(sq));
        if (piece == null) continue;
        final side = _side(piece.color);
        if (piece.role == Role.king) {
          // The king always takes slot 0; whatever was there goes to the end.
          if (counts[side] > 0) {
            final displaced = squares[side][0];
            squares[side][counts[side]] = displaced;
            slotOf[displaced] = counts[side];
          }
          squares[side][0] = sq;
          slotOf[sq] = 0;
        } else {
          slotOf[sq] = counts[side];
          squares[side][counts[side]] = sq;
        }
        counts[side]++;
      }
    }
    return ScidPieceList._(squares, slotOf, counts);
  }

  /// A deep copy — taken when a variation branches off the line.
  ScidPieceList clone() => ScidPieceList._(
    [List<int>.of(_squares[0]), List<int>.of(_squares[1])],
    List<int>.of(_slotOf),
    List<int>.of(_counts),
  );

  /// The slot of the piece standing on [square], or -1 when empty.
  int slotOf(int square) => _slotOf[square];

  /// Live piece count for [side] — exposed for assertions and tests.
  int countOf(Side side) => _counts[_side(side)];

  /// The square occupied by [slot] of [side].
  int squareAt(Side side, int slot) => _squares[_side(side)][slot];

  void _move(int side, int slot, int toSquare) {
    _squares[side][slot] = toSquare;
    _slotOf[toSquare] = slot;
  }

  void _removeAt(int side, int square) {
    final slot = _slotOf[square];
    if (slot == _noSlot) return;
    _counts[side]--;
    final lastSquare = _squares[side][_counts[side]];
    // Swap-with-last: the final piece drops into the vacated slot.
    _squares[side][slot] = lastSquare;
    _slotOf[lastSquare] = slot;
    _slotOf[square] = _noSlot;
  }

  /// Apply a move that has already been validated against [before].
  ///
  /// [castleRookFrom]/[castleRookTo] are set only for castling, and are the
  /// rook's real squares (Scid stores the king on its standard g/c-file
  /// destination and moves the rook itself).
  void applyMove({
    required Side mover,
    required int from,
    required int to,
    required int? capturedSquare,
    int? castleRookFrom,
    int? castleRookTo,
  }) {
    final side = _side(mover);
    final enemy = side == _white ? _black : _white;

    if (capturedSquare != null) {
      _removeAt(enemy, capturedSquare);
    }

    final slot = _slotOf[from];
    _slotOf[from] = _noSlot;
    _move(side, slot, to);

    if (castleRookFrom != null && castleRookTo != null) {
      final rookSlot = _slotOf[castleRookFrom];
      _slotOf[castleRookFrom] = _noSlot;
      _move(side, rookSlot, castleRookTo);
    }
  }

  /// A null move touches nothing; kept explicit so callers read clearly.
  void applyNullMove() {}
}
