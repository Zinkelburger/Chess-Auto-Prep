/// ChessDB's raw score encoding, decoded once.
///
/// Both ChessDB faces — the cdbdirect dump and the cdb.php API — score moves
/// the same way: plain centipawns from the point of view of the side to move,
/// except that a forced mate is encoded as `±(30000 − ply)`.  Two copies of
/// that arithmetic is one copy too many, so it lives here.
library;

import '../../utils/eval_constants.dart';

/// Decode one raw ChessDB score into side-to-move centipawns plus, when the
/// score is a mate, the signed distance to it in plies.
({int stmCp, int? mate}) mapChessDbRawScoreStm(int raw) {
  if (raw.abs() > kMateCpBase) {
    final ply = 30000 - raw.abs();
    // Mate cp is deliberately pushed *past* the mate base rather than pulled
    // back from it — `-10000 - ply` for a mate against us. It matches the C
    // `chessdb_map_api_score` this ports, and every comparison downstream is
    // an ordering, so the exact magnitude past ±10000 never has to mean
    // anything. Do not "fix" it to the sqlite convention without checking
    // every eval-window guard that sees these numbers.
    return (
      stmCp: raw > 0 ? (kMateCpBase - ply) : (-kMateCpBase - ply),
      mate: raw > 0 ? ply : -ply,
    );
  }
  return (stmCp: raw, mate: null);
}
