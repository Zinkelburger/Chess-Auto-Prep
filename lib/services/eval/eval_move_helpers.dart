/// Cache-aware "evaluate the position after this move" helper.
///
/// Shared by the repertoire audit and hole-hunt services, which both sweep a
/// tree asking "how bad is the position once this move is played?" and both
/// need the cache-hit/miss counters for their progress reporting.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../engine/stockfish_pool.dart';
import '../eval_cache.dart';

/// Evaluate the position after playing [moveUci] from [fen], consulting
/// [cache] first (white-normalized cp at [depth]) and writing back on miss.
///
/// Returns `(whiteCp, cacheHits, cacheMisses)`. `whiteCp` is null when the
/// position or move is unparsable.
Future<(int?, int, int)> evalAfterMoveCached(
  StockfishPool pool,
  EvalCache cache,
  String fen,
  String moveUci,
  int depth,
) async {
  try {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final move = Move.parse(moveUci);
    if (move == null) return (null, 0, 0);
    final newPos = pos.play(move);
    final newFen = newPos.fen;

    final cached = await cache.getEvalCpWhite(newFen, minDepth: depth);
    if (cached != null) return (cached, 1, 0);

    final result = await pool.evaluateFen(newFen, depth);
    final isWhiteAfter = newPos.turn == Side.white;
    final whiteCp = isWhiteAfter
        ? (result.scoreCp ?? 0)
        : -(result.scoreCp ?? 0);

    cache.putEvalCpWhite(newFen, whiteCp, depth);

    return (whiteCp, 0, 1);
  } catch (e) {
    if (kDebugMode) debugPrint('[EvalMoveHelpers] Eval after move failed: $e');
    return (null, 0, 0);
  }
}
