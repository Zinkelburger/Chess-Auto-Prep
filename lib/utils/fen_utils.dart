/// Shared FEN utilities used across the app.
///
/// A FEN has up to 6 space-separated fields:
///   board  active  castling  en-passant  halfmove  fullmove
///
/// For position identity we only care about the first four (the "normalised"
/// form).  Half-move clock and full-move number are irrelevant when asking
/// "is this the same position?"
library;

import '../services/eval/eval_canonicalize.dart';

/// Strip a FEN down to its first four fields (board / active colour /
/// castling / en-passant) so that positions are compared correctly
/// regardless of move counters.
///
/// Delegates to [canonicalizeFen4] — the single 4-field reducer. Both names
/// feed PERSISTENT cache keys (eval DB, explorer/transposition caches), so
/// the two MUST stay identical: any divergence would silently orphan
/// previously written cache entries.
String normalizeFen(String fen) => canonicalizeFen4(fen);

/// Whether the side to move in [fen] is white.
///
/// Returns `false` if the FEN is malformed or has fewer than two fields.
bool isWhiteToMove(String fen) {
  final parts = fen.split(' ');
  return parts.length >= 2 && parts[1] == 'w';
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
