/// SAN/UCI conversion and cached-eval helpers shared by the repertoire
/// audit and hole-hunt services.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/opening_tree.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/eval_cache.dart';

String? uciToSan(String fen, String uci) {
  try {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final move = Move.parse(uci);
    if (move == null) return null;
    final (_, san) = pos.makeSan(move);
    return san;
  } catch (_) {
    return null;
  }
}

String? sanToUci(String fen, String san) {
  try {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final move = pos.parseSan(san);
    if (move == null) return null;
    return move.uci;
  } catch (_) {
    return null;
  }
}

/// Convert a UCI PV starting from [fen] into SAN, stopping at [maxPlies]
/// or at the first move that fails to parse/apply.
List<String> uciPvToSan(String fen, List<String> pv, {int? maxPlies}) {
  final sans = <String>[];
  try {
    Position pos = Chess.fromSetup(Setup.parseFen(fen));
    for (final uci in pv) {
      if (maxPlies != null && sans.length >= maxPlies) break;
      final move = Move.parse(uci);
      if (move == null) break;
      final (next, san) = pos.makeSan(move);
      sans.add(san);
      pos = next;
    }
  } catch (_) {
    // Return whatever converted cleanly.
  }
  return sans;
}

/// Check if playing [san] from [fen] transposes into a position already
/// covered in [tree] (the FEN after the move exists as a tree node).
bool doesMoveTranspose(String fen, String san, OpeningTree tree) {
  try {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final move = pos.parseSan(san);
    if (move == null) return false;
    final after = pos.play(move);
    final afterPrefix = after.fen.split(' ').take(4).join(' ');
    for (final key in tree.fenToNodes.keys) {
      if (key.split(' ').take(4).join(' ') == afterPrefix) return true;
    }
  } catch (_) {
    // Best-effort; failure here is non-fatal and intentionally ignored.
  }
  return false;
}

/// Evaluate the position after playing [moveUci] from [fen], consulting
/// [cache] first (white-normalized cp at [depth]) and writing back on miss.
///
/// Returns (whiteCp, cacheHits, cacheMisses).
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
    if (kDebugMode) debugPrint('[ChessMoveUtils] Eval after move failed: $e');
    return (null, 0, 0);
  }
}
