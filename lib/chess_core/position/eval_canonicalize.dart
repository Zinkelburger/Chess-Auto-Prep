/// Canonical 4-field FEN for transposition / eval DB keys.
///
/// Matches C [eval_canonicalize_fen]: truncate after the 4th space-separated
/// field (active color, castling, en passant).
library;

const int _space = 0x20;

/// Return [fen] truncated to the first four fields, or unchanged if fewer.
///
/// This is the single 4-field FEN reducer: `normalizeFen` in
/// `lib/utils/fen_utils.dart` delegates here. Both names feed PERSISTENT
/// cache keys, so any behavior change invalidates existing eval databases.
///
/// Scans code units rather than indexing characters: `fen[i]` allocates a
/// one-character string per position, and this runs once per ply in the
/// frequency scanner and behind every `normalizeFen` call.
String canonicalizeFen4(String fen) {
  var spaces = 0;
  for (var i = 0; i < fen.length; i++) {
    if (fen.codeUnitAt(i) == _space && ++spaces == 4) {
      return fen.substring(0, i);
    }
  }
  return fen;
}
