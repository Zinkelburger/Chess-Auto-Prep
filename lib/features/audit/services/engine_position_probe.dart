/// The engine questions the repertoire audit and the hole hunt both ask, with
/// the shared eval cache in the loop: a MultiPV discovery of a position, the
/// eval of the position after one move, and a deep single-PV verification.
///
/// Every centipawn that leaves this file is White-normalised; the sign flip
/// from the engine's side-to-move scores happens here and nowhere else in the
/// two services.
library;

import '../../../services/engine/stockfish_pool.dart';
import '../../../services/eval/eval_move_helpers.dart';
import '../../../services/eval_cache.dart';
import '../../../utils/chess_utils.dart' as chess_utils;
import '../../../utils/fen_utils.dart';

/// One MultiPV line at a position, resolved to SAN. Lists of these keep
/// engine order: the best line for the side to move first.
class DiscoveredCandidate {
  const DiscoveredCandidate({
    required this.uci,
    required this.san,
    required this.whiteCp,
  });

  final String uci;
  final String san;

  /// Eval after the move, White-normalised.
  final int whiteCp;
}

/// A deep single-PV search of one position.
class VerifiedEval {
  const VerifiedEval({required this.whiteCp, required this.pv});

  /// White-normalised, with a forced mate folded in.
  final int whiteCp;

  /// Principal variation in UCI, from the searched position.
  final List<String> pv;
}

/// Eval-cache hit and miss counters for one run.
///
/// They describe the lookups made while checking the repertoire's own moves:
/// each MultiPV discovery of an our-move position is an uncached lookup, and
/// each repertoire move outside those lines is a hit or a miss.
class EvalCacheStats {
  int hits = 0;
  int misses = 0;

  int get lookups => hits + misses;

  void reset() {
    hits = 0;
    misses = 0;
  }
}

class EnginePositionProbe {
  EnginePositionProbe({required StockfishPool pool, EvalCache? evalCache})
    : _pool = pool,
      _evalCache = evalCache ?? EvalCache.instance;

  final StockfishPool _pool;
  final EvalCache _evalCache;

  /// Counters for the run in progress; the services [EvalCacheStats.reset]
  /// them as a run starts.
  final EvalCacheStats stats = EvalCacheStats();

  /// Open the eval cache. Cheap after the first call.
  Future<void> init() => _evalCache.init();

  /// MultiPV lines at [fen] in engine order, SAN-resolved, with the best
  /// line's eval cached for the generation pipeline. Empty when the engine
  /// had nothing to say. A line whose move cannot be converted to SAN is
  /// dropped: the SAN is compared against repertoire moves, so an echoed UCI
  /// string would only ever read as "not covered".
  ///
  /// With [countAsLookup] the search is counted as an eval-cache miss.
  Future<List<DiscoveredCandidate>> discover(
    String fen, {
    required int depth,
    required int multiPv,
    bool countAsLookup = false,
  }) async {
    final discovery = await _pool.discoverMoves(
      fen: fen,
      depth: depth,
      multiPv: multiPv,
      isWhiteToMove: isWhiteToMove(fen),
    );
    if (countAsLookup) stats.misses++;
    if (discovery.lines.isEmpty) return const [];

    remember(fen, discovery.lines.first.effectiveCp, depth);

    return [
      for (final line in discovery.lines)
        if (chess_utils.uciToSanOrNull(fen, line.moveUci) case final san?)
          DiscoveredCandidate(
            uci: line.moveUci,
            san: san,
            whiteCp: line.effectiveCp,
          ),
    ];
  }

  /// White-normalised eval after playing [moveUci] from [fen].
  ///
  /// Taken from [lines] when the discovery already searched that move; else
  /// from the cache at [depth] or deeper; else from a fresh search, which is
  /// cached. Null when the move cannot be played. Cache hits and misses are
  /// counted in [stats].
  Future<int?> evalAfterMove(
    String fen,
    String moveUci, {
    required List<DiscoveredCandidate> lines,
    required int depth,
  }) async {
    for (final line in lines) {
      if (line.uci == moveUci) return line.whiteCp;
    }
    final eval = await evalAfterMoveCached(
      _pool,
      _evalCache,
      fen,
      moveUci,
      depth,
    );
    stats.hits += eval.hits;
    stats.misses += eval.misses;
    return eval.whiteCp;
  }

  /// Deep single-PV search of [fen], cached at [depth].
  Future<VerifiedEval> verify(String fen, {required int depth}) async {
    final result = await _pool.evaluateFen(fen, depth);
    // `effectiveCp` folds a forced mate into the score the way the discovery
    // lines do. Reading `scoreCp` raw scored a mate as 0.00, so a repertoire
    // move that loses by force verified as "no loss at all".
    final whiteCp = isWhiteToMove(fen)
        ? result.effectiveCp
        : -result.effectiveCp;
    remember(fen, whiteCp, depth);
    return VerifiedEval(whiteCp: whiteCp, pv: result.pv);
  }

  /// Store a White-normalised eval for [fen] without waiting on the write.
  void remember(String fen, int whiteCp, int depth) =>
      _evalCache.putEvalCpWhiteSoon(fen, whiteCp, depth);
}
