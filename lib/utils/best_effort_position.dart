/// Best-effort board position builder for preview rendering.
///
/// Given arbitrary input (FEN, SAN moves, or SAN with [gap] markers), produces
/// a Chess position suitable for display. Illegal placements are handled by
/// directly manipulating the Board -- the resulting position may not be legal
/// but will render correctly in ChessBoardWidget.
library;

import 'package:dartchess/dartchess.dart';

import 'fen_utils.dart';
import 'san_token_utils.dart';

/// Attempt to build a renderable [Position] from [input].
///
/// Returns null if the input is empty or completely unparseable.
/// The returned position may be illegal (constructed without validation)
/// but is guaranteed to have a non-empty board for rendering.
Position? bestEffortPositionFromInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  // Case 1: FEN (contains '/')
  if (trimmed.contains('/')) {
    return _fromFen(trimmed);
  }

  // Case 2/3: SAN moves, possibly with [gap] markers
  return _fromMoveSequence(trimmed);
}

Position? _fromFen(String input) {
  try {
    final fullFen = expandFen(input);
    return Chess.fromSetup(
      Setup.parseFen(fullFen),
      ignoreImpossibleCheck: true,
    );
  } catch (_) {
    return null;
  }
}

Position? _fromMoveSequence(String input) {
  final groups = _splitOnGaps(input);
  if (groups.isEmpty) return null;

  Position pos = Chess.initial;
  int ply = 0;

  for (int g = 0; g < groups.length; g++) {
    final tokens = _tokenize(groups[g]);

    for (final token in tokens) {
      final legalResult = _tryLegalMove(pos, token);
      if (legalResult != null) {
        pos = legalResult;
      } else {
        // Illegal move -- place the piece directly on the board
        pos = _forcePlacePiece(pos, token, ply);
      }
      ply++;
    }

    // After each group (except the last), advance one ply for the gap
    if (g < groups.length - 1) {
      pos = _advanceTurn(pos);
      ply++;
    }
  }

  return pos;
}

/// Split input on `[gap]` markers, returning the text segments between them.
List<String> _splitOnGaps(String input) {
  return input
      .split(RegExp(r'\[gap\]', caseSensitive: false))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Tokenize a move group: strip move numbers and results, split on whitespace.
List<String> _tokenize(String group) => cleanSanTokens(group);

/// Try to play [san] as a legal move from [pos].
Position? _tryLegalMove(Position pos, String san) {
  try {
    final move = pos.parseSan(san);
    if (move == null) return null;
    return pos.play(move);
  } catch (_) {
    return null;
  }
}

/// Force-place a piece on the board by parsing the SAN token for piece type
/// and destination square. The resulting position skips validation.
Position _forcePlacePiece(Position pos, String san, int ply) {
  // Handle castling by moving king + rook directly
  final castleResult = _tryCastleFallback(pos, san, ply);
  if (castleResult != null) return castleResult;

  final parsed = _parseSanFallback(san, ply);
  if (parsed == null) return _advanceTurn(pos);

  final (piece, square) = parsed;
  final newBoard = pos.board.setPieceAt(square, piece);
  final newTurn = pos.turn.opposite;

  return Chess(
    board: newBoard,
    turn: newTurn,
    castles: Castles.empty,
    halfmoves: 0,
    fullmoves: (ply ~/ 2) + 1,
  );
}

/// Handle castling by manually repositioning king and rook.
Position? _tryCastleFallback(Position pos, String san, int ply) {
  final cleaned = san.replaceAll(RegExp(r'[+#!?]'), '');
  final isWhite = ply.isEven;
  final rank = isWhite ? 0 : 7; // rank index: 0=1st rank, 7=8th rank

  Square sq(int file, int r) => Square(file + r * 8);

  if (cleaned == 'O-O' || cleaned == '0-0') {
    // Kingside: king e→g, rook h→f
    var board = pos.board
        .removePieceAt(sq(4, rank)) // remove king from e-file
        .removePieceAt(sq(7, rank)); // remove rook from h-file
    board = board
        .setPieceAt(
          sq(6, rank),
          Piece(color: isWhite ? Side.white : Side.black, role: Role.king),
        )
        .setPieceAt(
          sq(5, rank),
          Piece(color: isWhite ? Side.white : Side.black, role: Role.rook),
        );
    return Chess(
      board: board,
      turn: pos.turn.opposite,
      castles: Castles.empty,
      halfmoves: 0,
      fullmoves: (ply ~/ 2) + 1,
    );
  }

  if (cleaned == 'O-O-O' || cleaned == '0-0-0') {
    // Queenside: king e→c, rook a→d
    var board = pos.board
        .removePieceAt(sq(4, rank)) // remove king from e-file
        .removePieceAt(sq(0, rank)); // remove rook from a-file
    board = board
        .setPieceAt(
          sq(2, rank),
          Piece(color: isWhite ? Side.white : Side.black, role: Role.king),
        )
        .setPieceAt(
          sq(3, rank),
          Piece(color: isWhite ? Side.white : Side.black, role: Role.rook),
        );
    return Chess(
      board: board,
      turn: pos.turn.opposite,
      castles: Castles.empty,
      halfmoves: 0,
      fullmoves: (ply ~/ 2) + 1,
    );
  }

  return null;
}

/// Advance the turn without making a move (for gap plies).
Position _advanceTurn(Position pos) {
  return Chess(
    board: pos.board,
    turn: pos.turn.opposite,
    castles: Castles.empty,
    halfmoves: 0,
    fullmoves: pos.fullmoves,
  );
}

/// Parse a SAN token to extract piece type and destination square.
///
/// Returns null if the destination square can't be determined.
(Piece, Square)? _parseSanFallback(String san, int ply) {
  // Strip check/mate indicators and capture notation
  var s = san.replaceAll(RegExp(r'[+#!?]'), '');

  // Handle castling -- can't meaningfully place without context
  if (s == 'O-O' || s == 'O-O-O') return null;

  final color = ply.isEven ? Side.white : Side.black;

  // Handle promotion: e8=Q, exd8=N, etc.
  Role role = Role.pawn;
  final promoMatch = RegExp(r'=([NBRQ])').firstMatch(s);
  if (promoMatch != null) {
    role = _charToRole(promoMatch.group(1)!) ?? Role.pawn;
    s = s.substring(0, promoMatch.start);
  } else {
    // Determine piece from first character
    if (s.isNotEmpty && 'NBRQK'.contains(s[0])) {
      role = _charToRole(s[0]) ?? Role.pawn;
      s = s.substring(1);
    }
  }

  // Remove capture indicator
  s = s.replaceAll('x', '');

  // The destination square is the last two characters
  if (s.length < 2) return null;
  final squareStr = s.substring(s.length - 2);
  final square = Square.parse(squareStr);
  if (square == null) return null;

  final piece = Piece(color: color, role: role);
  return (piece, square);
}

Role? _charToRole(String c) => switch (c) {
  'N' => Role.knight,
  'B' => Role.bishop,
  'R' => Role.rook,
  'Q' => Role.queen,
  'K' => Role.king,
  'P' => Role.pawn,
  _ => null,
};
