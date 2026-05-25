/// Canonical 4-field FEN for transposition / eval DB keys.
///
/// Matches C [eval_canonicalize_fen]: truncate after the 4th space-separated
/// field (active color, castling, en passant).
library;

/// Return [fen] truncated to the first four fields, or unchanged if fewer.
String canonicalizeFen4(String fen) {
  var spaces = 0;
  for (var i = 0; i < fen.length; i++) {
    if (fen[i] == ' ' && ++spaces == 4) {
      return fen.substring(0, i);
    }
  }
  return fen;
}
