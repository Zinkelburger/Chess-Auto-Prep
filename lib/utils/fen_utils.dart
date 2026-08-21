/// Shared FEN utilities used across the app.
///
/// A FEN has up to 6 space-separated fields:
///   board  active  castling  en-passant  halfmove  fullmove
///
/// For position identity we only care about the first four (the "normalised"
/// form).  Half-move clock and full-move number are irrelevant when asking
/// "is this the same position?"
///
/// **Every reader here is total.**  None throws, and none needs the caller to
/// check the field count first — indexing `fen.split(' ')[1]` by hand is what
/// put [RangeError]s in the planner and the game-analysis controller.
///
/// The fallbacks are deliberately consistent with one another rather than each
/// guessing separately: a missing full-move field reads as 1, and only an
/// explicit `w` reads as White, so [plyFromFen] — which is defined from the
/// other two — can never contradict either.  The adversarial-input contract in
/// `test/services/fen_move_validation_test.dart` pins that behaviour.
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
/// That fallback is pinned by `test/services/fen_move_validation_test.dart`
/// — only an explicit `w` is White.
bool isWhiteToMove(String fen) {
  final parts = fen.split(' ');
  return parts.length >= 2 && parts[1] == 'w';
}

/// Full-move number of [fen] — the number a PGN emitter must start counting
/// from when its movetext begins at this position.  Defaults to 1 for short
/// or malformed FENs, which is the standard start's value.
int fullMoveNumber(String fen) {
  final parts = fen.split(' ');
  if (parts.length < 6) return 1;
  return int.tryParse(parts[5]) ?? 1;
}

/// Zero-based ply index of the position [fen] describes, counting from move 1
/// with White to move: `1. e4` is played at ply 0, `1... e5` at ply 1.
///
/// This is what a movetext renderer needs to number a line that starts from an
/// arbitrary position.  Defined purely in terms of [fullMoveNumber] and
/// [isWhiteToMove] so it can never contradict them: `ply.isEven` always equals
/// [isWhiteToMove], and `ply ~/ 2 + 1` always equals [fullMoveNumber], on every
/// input including malformed ones.
int plyFromFen(String fen) =>
    (fullMoveNumber(fen) - 1) * 2 + (isWhiteToMove(fen) ? 0 : 1);

/// Expand a possibly-short (4-field) FEN into a full 6-field FEN by appending
/// default half-move clock 0 and full-move number 1.  Needed by libraries that
/// require a complete FEN string (e.g. `chess.Chess.fromFEN`).
String expandFen(String fen) {
  final fields = fen.split(' ').length;
  if (fields == 4) return '$fen 0 1';
  if (fields == 5) return '$fen 1';
  return fen;
}
