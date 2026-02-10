/// Shared FEN utilities used across the app.
///
/// A FEN has up to 6 space-separated fields:
///   board  active  castling  en-passant  halfmove  fullmove
///
/// For position identity we only care about the first four (the "normalised"
/// form).  Half-move clock and full-move number are irrelevant when asking
/// "is this the same position?"
library;

/// Strip a FEN down to its first four fields (board / active colour /
/// castling / en-passant) so that positions are compared correctly
/// regardless of move counters.
String normalizeFen(String fen) {
  final parts = fen.split(' ');
  if (parts.length >= 4) {
    return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
  }
  return fen;
}

/// Expand a possibly-short (4-field) FEN into a full 6-field FEN by appending
/// default half-move clock 0 and full-move number 1.  Needed by libraries that
/// require a complete FEN string (e.g. `chess.Chess.fromFEN`).
String expandFen(String fen) {
  final fields = fen.split(' ').length;
  if (fields == 4) return '$fen 0 1';
  if (fields == 5) return '$fen 1';
  return fen;
}
