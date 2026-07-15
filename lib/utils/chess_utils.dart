/// Shared chess move-conversion and formatting utilities.
///
/// Centralises UCI ↔ SAN helpers that were duplicated in
/// [UnifiedEnginePane] and [RepertoireScreen].
library;

import 'package:dartchess/dartchess.dart';

/// Convert a UCI move string (e.g. `e2e4`) to SAN notation given [fen].
///
/// Returns the original [uci] string if the move cannot be resolved.
String uciToSan(String fen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final move = Move.parse(uci);
    if (move == null) return uci;
    final (_, san) = position.makeSan(move);
    return san;
  } catch (_) {
    return uci;
  }
}

/// Convert a SAN move to standard UCI in the position given by [fen].
///
/// Returns `null` when the SAN is not legal in the position.  Castling is
/// emitted in the king→destination convention (see [toStandardUci]).
String? sanToUci(String fen, String san) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final move = position.parseSan(san);
    if (move == null) return null;
    if (move is NormalMove) {
      final uci = toStandardUci(position, move.from, move.to);
      final promotion = move.promotion;
      return promotion != null
          ? '$uci${roleChar(promotion).toLowerCase()}'
          : uci;
    }
    return move.uci;
  } catch (_) {
    return null;
  }
}

/// Format a PV continuation (skip the first move) as SAN text.
///
/// Returns at most [maxMoves] SAN tokens joined by spaces.
String formatContinuation(String fen, List<String> fullPv, {int maxMoves = 6}) {
  if (fullPv.length <= 1) return '';

  try {
    Position pos = Chess.fromSetup(Setup.parseFen(fen));
    final sanMoves = <String>[];

    for (int i = 0; i < fullPv.length && sanMoves.length < maxMoves; i++) {
      final uci = fullPv[i];
      final move = Move.parse(uci);
      if (move == null) break;

      try {
        if (i >= 1) {
          final (_, san) = pos.makeSan(move);
          sanMoves.add(san);
        }
        pos = pos.play(move);
      } catch (_) {
        break;
      }
    }

    return sanMoves.join(' ');
  } catch (_) {
    return '';
  }
}

/// Play a UCI move on [baseFen] and return the resulting FEN, or `null`
/// if the move is illegal.
String? playUciMove(String baseFen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(baseFen));
    final move = Move.parse(uci);
    if (move == null) return null;
    final newPos = position.play(move);
    return newPos.fen;
  } catch (_) {
    return null;
  }
}

/// Parse a FEN into a [Position], returning null if invalid.
Position? tryParseFen(String fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen));
  } catch (_) {
    return null;
  }
}

/// 0-based half-move (ply) index, counted from a game that starts at
/// [startFullmoves]/[startWhiteToMove], of the position *just before* the move
/// numbered [moveNumber] played by White (when [isWhite]) or Black.
///
/// This is the branch point for an inline analysis line: replaying that many
/// mainline plies from the start lands on the position the line departs from.
/// Unlike the naive `(moveNumber - startFullmoves) * 2` it stays correct when
/// the game starts from a Black-to-move FEN (where ply 0 is a Black move).
///
/// The result is NOT clamped to any mainline length — callers should clamp.
int plyBeforeMove({
  required int moveNumber,
  required bool isWhite,
  required int startFullmoves,
  required bool startWhiteToMove,
}) {
  final startAbsPly = (startFullmoves - 1) * 2 + (startWhiteToMove ? 0 : 1);
  final moveAbsPly = (moveNumber - 1) * 2 + (isWhite ? 0 : 1);
  return moveAbsPly - startAbsPly;
}

/// Inverse of [plyBeforeMove]: the (fullmove number, side) of the move played
/// [ply] half-moves into a game starting at [startFullmoves]/[startWhiteToMove].
({int moveNumber, bool isWhite}) coordsAtPly({
  required int ply,
  required int startFullmoves,
  required bool startWhiteToMove,
}) {
  final abs = ply + (startWhiteToMove ? 0 : 1);
  return (moveNumber: (abs ~/ 2) + startFullmoves, isWhite: abs.isEven);
}

/// Parse an algebraic square name (e.g. 'e4') to a dartchess [Square].
Square? parseSquare(String name) => Square.parse(name);

/// Convert a dartchess [Square] to algebraic notation (e.g. 'e4').
String toAlgebraic(Square square) => square.name;

// =====================================================================
// Castling move encoding — the single source of truth.
//
// dartchess encodes castling as the king moving onto its OWN ROOK's square
// (e1h1 / e1a1), and [Position.legalMoves] only ever emits such a king target
// when the castle is actually legal: rook present and unmoved, castling rights
// intact, path clear, and the king not passing through check. The rest of the
// chess world (UCI, chess.js, Stockfish, Leela/Maia) uses the king→destination
// encoding (e1g1 / e1c1).
//
// Deciding "is this castling?" from the raw square-index distance is the source
// of a whole class of bugs: a vertical king move (e1→e2) spans 8 indices and a
// diagonal one (e1→d2/f2) spans 7/9, so they all look like they jump more than
// two squares and get mistaken for a castle. The only correct test is whether
// the destination holds the mover's own rook. Always route through these
// helpers instead of re-deriving the rule.
// =====================================================================

/// Whether the king move [from]→[to] — as produced by [Position.legalMoves] —
/// is a castling move, i.e. [to] holds the side-to-move's own rook.
///
/// Because dartchess only emits this king target when castling is genuinely
/// legal, a `true` result also guarantees the castle is valid (rook unmoved,
/// rights intact, path clear, king not passing through check).
bool isCastlingMove(Position position, Square from, Square to) {
  final king = position.board.pieceAt(from);
  if (king?.role != Role.king) return false;
  final dest = position.board.pieceAt(to);
  return dest != null && dest.role == Role.rook && dest.color == king!.color;
}

/// The square the king visually lands on for the king move [from]→[to],
/// translating dartchess's king→rook castling encoding into the standard
/// king→destination convention. Returns [to] unchanged for normal king moves
/// (and non-king moves).
Square castlingKingDestination(Position position, Square from, Square to) {
  if (!isCastlingMove(position, from, to)) return to;
  // King and rook share a rank, so moving two files stays on the rank. Rook on
  // the higher file (kingside) → king lands on the g-file; rook on the lower
  // file (queenside) → king lands on the c-file.
  return to > from ? Square(from + 2) : Square(from - 2);
}

/// Standard UCI for the move [from]→[to] in [position], normalising dartchess's
/// king→rook castling encoding (e1h1) to the king→destination convention
/// (e1g1) that Stockfish, Lichess and Leela/Maia use. Non-castling moves are
/// returned verbatim as `<from><to>`.
String toStandardUci(Position position, Square from, Square to) =>
    '${from.name}${castlingKingDestination(position, from, to).name}';

/// Role to uppercase character for SVG asset filenames (e.g. Role.pawn → 'P').
String roleChar(Role role) => switch (role) {
  Role.pawn => 'P',
  Role.knight => 'N',
  Role.bishop => 'B',
  Role.rook => 'R',
  Role.queen => 'Q',
  Role.king => 'K',
};

/// Format a centipawn / mate score for display (e.g. `+1.3`, `-0.5`, `#3`).
///
/// Uses one decimal place for centipawns and `#N` for mate scores.
/// Returns `'--'` when both values are null.
String formatEvalDisplay({int? scoreCp, int? scoreMate}) {
  if (scoreMate != null) return '#$scoreMate';
  if (scoreCp != null) {
    final v = scoreCp / 100.0;
    return v >= 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1);
  }
  return '--';
}

/// Convert a UCI principal-variation list to SAN move strings.
///
/// Walks the position forward from [fen], converting up to [maxMoves]
/// UCI tokens to SAN. Returns an empty list on any parse error.
List<String> uciPvToSan(String fen, List<String> uciMoves, {int maxMoves = 8}) {
  if (uciMoves.isEmpty) return const [];
  try {
    Position pos = Chess.fromSetup(Setup.parseFen(fen));
    final san = <String>[];
    for (final uci in uciMoves.take(maxMoves)) {
      final move = Move.parse(uci);
      if (move == null) break;
      final (newPos, sanStr) = pos.makeSan(move);
      san.add(sanStr);
      pos = newPos;
    }
    return san;
  } catch (_) {
    return const [];
  }
}

/// Format a large integer with k/M suffixes, using [mDecimals] decimal places
/// at the millions threshold and [kDecimals] at the thousands threshold.
String _formatWithSuffix(
  int value, {
  required int mDecimals,
  required int kDecimals,
}) {
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(mDecimals)}M';
  }
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(kDecimals)}k';
  return value.toString();
}

/// Format a large integer with k/M suffixes.
String formatCount(int count) =>
    _formatWithSuffix(count, mDecimals: 1, kDecimals: 0);

/// Format a node count with k/M suffixes (one decimal for M and k).
String formatNodes(int nodes) =>
    _formatWithSuffix(nodes, mDecimals: 1, kDecimals: 1);

/// Format NPS with k/M suffixes.
String formatNps(int nps) => _formatWithSuffix(nps, mDecimals: 1, kDecimals: 0);

/// Compute the FEN after playing [sanMoves] from [startFen] up to [upToIndex].
///
/// Returns [startFen] if no moves can be parsed.
String fenAfterMoves(String startFen, List<String> sanMoves, int upToIndex) {
  try {
    Position pos = Chess.fromSetup(Setup.parseFen(startFen));
    for (int i = 0; i <= upToIndex && i < sanMoves.length; i++) {
      final move = pos.parseSan(sanMoves[i]);
      if (move == null) break;
      pos = pos.play(move);
    }
    return pos.fen;
  } catch (_) {
    return startFen;
  }
}

/// From/to squares for highlighting the last move on a mini board.
Set<String> uciHighlightSquares(String uci) {
  if (uci.length < 4) return const {};
  return {uci.substring(0, 2), uci.substring(2, 4)};
}
