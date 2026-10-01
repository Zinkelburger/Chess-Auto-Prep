import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';

/// A position as FEN text.
///
/// Kept as text rather than a dartchess `Position` because text is what PGN
/// headers, caches and databases hold, and a position is cheap to rebuild
/// from it when a board or move generator needs one. Wrapping it stops a FEN
/// from being passed where a SAN, a UCI move or a file path was meant.
extension type const Fen(String value) {
  static const initial = Fen(
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  );

  /// Whose move it is, read from the second FEN field; a malformed FEN reads
  /// as White to move, which is the harmless default for display.
  bool get whiteToMove => _field(1) != 'b';

  /// The full-move number, 1 when the field is missing or not a number.
  int get fullMove => int.tryParse(_field(5) ?? '') ?? 1;

  /// The four fields that make a position — pieces, side, castling, en
  /// passant — without the move counters: what two positions reached by
  /// different roads have in common, and what a model or a cache keys on.
  String get position => value.substring(0, _positionEnd(value));

  /// Whether this is the position [position] names ([Fen.position]), asked
  /// without cutting this one's out: a search of a file's games asks it of
  /// every move of every game.
  bool isAt(String position) =>
      value.startsWith(position) && _positionEnd(value) == position.length;

  String? _field(int index) {
    final fields = value.split(' ');
    return index < fields.length ? fields[index] : null;
  }
}

const _fnvOffset = -3750763034362895579; // 0xcbf29ce484222325 as signed
const _fnvPrime = 1099511628211;

/// The key the old app's databases file a position under: 64-bit FNV-1a
/// over [Fen.position], the same sum its importers and the Python tools
/// take, so a row they wrote is found. Two roads to one position share it.
///
/// The sum is taken over the FEN's own characters up to where the move
/// counters start: an index of a file's games takes one for every move of
/// every game, and cutting the text out first cost more than summing it.
int positionKey(Fen fen) {
  final text = fen.value;
  final end = _positionEnd(text);
  var hash = _fnvOffset;
  for (var i = 0; i < end; i++) {
    hash ^= text.codeUnitAt(i);
    hash *= _fnvPrime;
  }
  return hash;
}

/// Where [Fen.position] ends in [fen]: at its fourth space, or at its end
/// when it has fewer fields than that.
int _positionEnd(String fen) {
  var spaces = 0;
  for (var i = 0; i < fen.length; i++) {
    if (fen.codeUnitAt(i) == _space && ++spaces == 4) return i;
  }
  return fen.length;
}

/// [position] as FEN: what dartchess's `Position.fen` answers, character
/// for character, at about a fifth of the cost.
///
/// Reading a file writes the FEN of every position of every game, and
/// dartchess builds each from a `Piece` per square, a list of fields and a
/// join, which comes to a third of the whole read. This writes the same
/// characters straight from the bitboards. The castling field and the en
/// passant square follow dartchess's own rules — a square is written only
/// when a pawn can legally capture on it. Anything but a standard chess
/// position is left to dartchess.
Fen fenOf(Position position) {
  final board = position.board;
  if (position is! Chess ||
      position.pockets != null ||
      board.promoted.isNotEmpty) {
    return Fen(position.fen);
  }
  var n = _pieces(board);
  if (n < 0) return Fen(position.fen);
  final out = _fenChars;
  out[n++] = _space;
  out[n++] = position.turn == Side.white ? 0x77 : 0x62; // w, b
  out[n++] = _space;
  n = _ascii(_castling(board, position.castles.castlingRights), n);
  out[n++] = _space;
  n = _ascii(_legalEpSquare(position)?.name ?? '-', n);
  out[n++] = _space;
  n = _ascii('${position.halfmoves.clamp(0, 9999)}', n);
  out[n++] = _space;
  n = _ascii('${position.fullmoves.clamp(1, 9999)}', n);
  return Fen(String.fromCharCodes(out, 0, n));
}

const _space = 0x20;

/// One FEN being written. Nothing reads it across a call.
final _fenChars = Uint8List(128);

/// Writes [board]'s field of a FEN to [_fenChars] and answers its length,
/// or -1 for a board with a square that is somebody's and nothing's.
int _pieces(Board board) {
  final out = _fenChars;
  final white = board.white.value;
  final occupied = white | board.black.value;
  final pawns = board.pawns.value;
  final knights = board.knights.value;
  final bishops = board.bishops.value;
  final rooks = board.rooks.value;
  final queens = board.queens.value;
  final kings = board.kings.value;
  var n = 0;
  for (var rank = 7; rank >= 0; rank--) {
    var empty = 0;
    for (var file = 0; file < 8; file++) {
      final bit = 1 << (rank * 8 + file);
      if (occupied & bit == 0) {
        empty++;
        continue;
      }
      if (empty > 0) out[n++] = 0x30 + empty;
      empty = 0;
      final letter = pawns & bit != 0
          ? 0x70
          : knights & bit != 0
          ? 0x6e
          : bishops & bit != 0
          ? 0x62
          : rooks & bit != 0
          ? 0x72
          : queens & bit != 0
          ? 0x71
          : kings & bit != 0
          ? 0x6b
          : -1;
      if (letter < 0) return -1;
      // An upper-case letter is the lower-case one less 0x20.
      out[n++] = white & bit != 0 ? letter - 0x20 : letter;
    }
    if (empty > 0) out[n++] = 0x30 + empty;
    if (rank > 0) out[n++] = 0x2f;
  }
  return n;
}

int _ascii(String text, int at) {
  for (var i = 0; i < text.length; i++) {
    _fenChars[at + i] = text.codeUnitAt(i);
  }
  return at + text.length;
}

/// The castling field of the last position asked about, by everything it
/// is worked out from: one game asks about the same rights, kings and
/// rooks move after move.
(int, int, int, int, int)? _castlingOf;
String _castlingField = '-';

/// dartchess's `_makeCastlingFen`, which is private to it: `K`/`Q` for the
/// outermost rook on its king's side, else the rook's file.
String _castling(Board board, SquareSet rights) {
  if (rights.isEmpty) return '-';
  final whiteRooks =
      board.piecesOf(Side.white, Role.rook) & SquareSet.backrankOf(Side.white);
  final blackRooks =
      board.piecesOf(Side.black, Role.rook) & SquareSet.backrankOf(Side.black);
  final whiteKing = board.kingOf(Side.white);
  final blackKing = board.kingOf(Side.black);
  final key = (
    rights.value,
    whiteRooks.value,
    blackRooks.value,
    whiteKing ?? -1,
    blackKing ?? -1,
  );
  if (key == _castlingOf) return _castlingField;
  final buffer = StringBuffer();
  for (final (color, king, candidates) in [
    (Side.white, whiteKing, whiteRooks),
    (Side.black, blackKing, blackRooks),
  ]) {
    final white = color == Side.white;
    for (final rook in (rights & SquareSet.backrankOf(color)).squaresReversed) {
      if (rook == candidates.first && king != null && rook < king) {
        buffer.write(white ? 'Q' : 'q');
      } else if (rook == candidates.last && king != null && king < rook) {
        buffer.write(white ? 'K' : 'k');
      } else {
        final file = rook.file.name;
        buffer.write(white ? file.toUpperCase() : file);
      }
    }
  }
  final field = buffer.isEmpty ? '-' : buffer.toString();
  _castlingOf = key;
  return _castlingField = field;
}

/// dartchess's `_legalEpSquare`, which is private to it: the en passant
/// square when a pawn of the side to move can legally capture there.
Square? _legalEpSquare(Position position) {
  final square = position.epSquare;
  if (square == null) return null;
  final turn = position.turn;
  final candidates =
      position.board.piecesOf(turn, Role.pawn) &
      pawnAttacks(turn.opposite, square);
  for (final from in candidates.squares) {
    if (position.legalMovesOf(from).has(square)) return square;
  }
  return null;
}
