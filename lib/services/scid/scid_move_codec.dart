/// Scid's one-byte move encoding, ported from `src/game.cpp:2489-2596`.
///
/// High nibble: the moving piece's slot in [ScidPieceList]. Low nibble: a
/// direction code whose meaning depends on the piece type. The king is always
/// slot 0 and has at most 8 real destinations, which leaves low-nibble values
/// 9-15 free for the tokens below.
///
/// Only queen *diagonal* moves need a second byte.
///
/// The tables here are transcriptions of facts about a file format, checked
/// against Scid's own `gtest/test_decodemove.cpp` vectors.
library;

/// Special tokens, encoded as king (slot 0) "moves".
class ScidToken {
  const ScidToken._();

  /// A king move to its own square.
  static const int nullMove = 0;
  static const int castleQueenside = 9;
  static const int castleKingside = 10;
  static const int nag = 11;

  /// Marks that a comment belongs here; the text itself is stored after the
  /// move list.
  static const int comment = 12;
  static const int startVariation = 13;
  static const int endVariation = 14;
  static const int endGame = 15;
}

int _rankOf(int square) => square >> 3;
int _fileOf(int square) => square & 7;

/// King moves: diffs -9,-8,-7,-1,1,7,8,9 map to 1-8; ±2 are the castles.
/// Index is `diff + 9`.
const List<int> _kingTable = [
  1,
  2,
  3,
  0,
  0,
  0,
  0,
  9,
  4,
  0,
  5,
  10,
  0,
  0,
  0,
  0,
  6,
  7,
  8,
];

/// Knight moves: diffs ±6, ±10, ±15, ±17 map to 1-8. Index is `diff + 17`.
const List<int> _knightTable = [
  1, 0, 2, 0, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 5, 0, 0, 0, 6, 0, 0, 0, 0, 7, 0, 8,
];

/// A single encoded move: one byte, plus a second for queen diagonals.
class ScidEncodedMove {
  const ScidEncodedMove(this.first, [this.second]);
  final int first;
  final int? second;
}

/// Encode a king move. Pass [to] as `from ± 2` for castling — Scid encodes the
/// castle by the king's nominal two-square shift regardless of where the rook
/// actually sat (which is how Chess960 stays representable).
int encodeKingCode(int from, int to) {
  final diff = to - from;
  if (diff < -9 || diff > 9) {
    throw ArgumentError('king move $from->$to is not encodable');
  }
  return _kingTable[diff + 9];
}

int encodeKnightCode(int from, int to) {
  final diff = to - from;
  if (diff < -17 || diff > 17 || _knightTable[diff + 17] == 0) {
    throw ArgumentError('knight move $from->$to is not encodable');
  }
  return _knightTable[diff + 17];
}

/// Rook: same rank → the destination file (0-7); same file → `8 + rank`.
int encodeRookCode(int from, int to) {
  if (_rankOf(from) == _rankOf(to)) return _fileOf(to);
  return 8 + _rankOf(to);
}

/// Bishop: the destination file, `+8` when the diagonal runs up-left /
/// down-right.
int encodeBishopCode(int from, int to) {
  final rankDiff = _rankOf(to) - _rankOf(from);
  final fileDiff = _fileOf(to) - _fileOf(from);
  if (rankDiff * fileDiff < 0) return _fileOf(to) + 8;
  return _fileOf(to);
}

/// Pawn: 0/1/2 = capture-left / forward / capture-right, `+3 * (promo - 1)`
/// for a promotion, 15 for a double push.
///
/// [promoIndex] is 0 for no promotion, else 1=queen, 2=rook, 3=bishop,
/// 4=knight — matching Scid's `QUEEN..KNIGHT` ordering.
int encodePawnCode(int from, int to, int promoIndex) {
  var diff = to - from;
  if (diff < 0) diff = -diff;
  if (diff == 16) return 15; // double push, never a promotion
  int val;
  switch (diff) {
    case 7:
      val = 0;
      break;
    case 8:
      val = 1;
      break;
    case 9:
      val = 2;
      break;
    default:
      throw ArgumentError('pawn move $from->$to is not encodable');
  }
  if (promoIndex != 0) val += 3 * promoIndex;
  return val;
}

/// Queen: rook-like moves exactly as a rook, in one byte. A diagonal needs
/// two: the first byte encodes a bogus rook-horizontal move *to the from
/// square* as a marker, the second is `to + 64` — the `+64` keeps it clear of
/// the special tokens.
ScidEncodedMove encodeQueenMove(int slot, int from, int to) {
  if (_rankOf(from) == _rankOf(to)) {
    return ScidEncodedMove((slot << 4) | _fileOf(to));
  }
  if (_fileOf(from) == _fileOf(to)) {
    return ScidEncodedMove((slot << 4) | (8 + _rankOf(to)));
  }
  return ScidEncodedMove((slot << 4) | _fileOf(from), to + 64);
}

/// Assemble a byte from a piece slot and a direction code.
int scidMoveByte(int slot, int code) => (slot << 4) | code;
