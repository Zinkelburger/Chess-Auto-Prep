/// Shared 3-phase eval resolution (cache → local → API → Stockfish).
library;

import '../../chess_core/generation/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import '../eval_cache.dart';
import '../generation/generation_config.dart';
import 'chessdb_api_provider.dart';
import 'external_eval_provider.dart';

enum EvalChainSource {
  transposition,
  projectCache,
  cdbDirect,
  localChessDb,
  lichessEvals,
  chessDbApi,
  stockfish,
}

/// What [resolveEvalChain] found, and where.
class EvalChainOutcome {
  final EvalChainSource? source;

  /// White-normalized centipawns, or null when no source answered.
  final int? whiteCp;
  final int depth;

  /// The external-eval mode the caller's subtree should continue in: flips to
  /// [ExtEvalMode.skipExternal] once every local database hard-missed.
  final ExtEvalMode extEvalMode;

  const EvalChainOutcome({
    this.source,
    this.whiteCp,
    this.depth = 0,
    this.extEvalMode = ExtEvalMode.none,
  });

  bool get resolved => whiteCp != null;
}

typedef StockfishEvalFn =
    Future<({int stmCp, int depth})> Function(String fen, int depth);

/// Resolve an eval using the configured external-source chain.
///
/// Returns [EvalChainOutcome] with [EvalChainOutcome.whiteCp] set when a
/// source succeeds. [stockfishEval] is invoked only when earlier sources
/// miss; [cacheWrite] persists every external or engine answer.
Future<EvalChainOutcome> resolveEvalChain({
  required String fen,
  required TreeBuildConfig config,
  required EvalCache cache,
  required BuildStats stats,
  ExternalEvalProvider? localChessDb,
  ExternalEvalProvider? cdbDirect,
  ExternalEvalProvider? lichessEvals,
  ChessDbApiProvider? chessDbApi,
  ExtEvalMode extEvalMode = ExtEvalMode.none,
  BuildTreeNode? canonicalNode,
  required StockfishEvalFn stockfishEval,
  Future<void> Function(String fen, int whiteCp, int depth)? cacheWrite,
  bool allowStockfishFallback = true,
}) async {
  var mode = extEvalMode;

  // Shared tail for a successful external-source lookup: persist to the project
  // cache (falling back to the configured depth) and build the outcome.
  Future<EvalChainOutcome> recordHit(
    EvalChainSource source,
    EvalHit hit,
  ) async {
    await cacheWrite?.call(
      fen,
      hit.cp,
      hit.depth > 0 ? hit.depth : config.evalDepth,
    );
    return EvalChainOutcome(
      source: source,
      whiteCp: hit.cp,
      depth: hit.depth,
      extEvalMode: mode,
    );
  }

  final canonicalCp = canonicalNode?.engineEvalCp;
  if (canonicalCp != null) {
    stats.transpositionEvalHits++;
    return EvalChainOutcome(
      source: EvalChainSource.transposition,
      whiteCp: isWhiteToMove(fen) ? canonicalCp : -canonicalCp,
      depth: config.evalDepth,
      extEvalMode: mode,
    );
  }

  final minDepth = config.effectiveMinEvalDepth;

  final cached = await cache.getEvalCpWhite(fen, minDepth: minDepth);
  if (cached != null) {
    stats.dbEvalHits++;
    return EvalChainOutcome(
      source: EvalChainSource.projectCache,
      whiteCp: cached,
      depth: minDepth,
      extEvalMode: mode,
    );
  }
  stats.dbEvalMisses++;

  final consultExternal = mode != ExtEvalMode.skipExternal;
  var localHardMiss = false;

  if (consultExternal && config.enableCdbDirect && cdbDirect != null) {
    switch (await cdbDirect.lookup(fen, minDepth: minDepth)) {
      case EvalLookupHit(:final hit):
        stats.cdbDirectHits++;
        return recordHit(EvalChainSource.cdbDirect, hit);
      case EvalLookupShallow():
        stats.cdbDirectShallow++;
      case EvalLookupHardMiss():
        stats.cdbDirectHardMisses++;
        localHardMiss = true;
      case EvalLookupMiss():
        stats.cdbDirectMisses++;
    }
  }

  if (consultExternal && config.enableLocalChessDb && localChessDb != null) {
    switch (await localChessDb.lookup(fen, minDepth: minDepth)) {
      case EvalLookupHit(:final hit):
        stats.localChessDbHits++;
        return recordHit(EvalChainSource.localChessDb, hit);
      case EvalLookupShallow():
        stats.localChessDbShallow++;
      case EvalLookupHardMiss():
        stats.localChessDbHardMisses++;
        localHardMiss = true;
      case EvalLookupMiss():
        stats.localChessDbMisses++;
    }
  }

  // Lichess publishes 394 million positions against ChessDB's 64 billion, so
  // it answers last among the local sources and — unlike them — a miss here
  // says nothing about the subtree, which is why it stays out of the
  // hard-miss bookkeeping below.
  if (consultExternal && config.enableLichessEvals && lichessEvals != null) {
    switch (await lichessEvals.lookup(fen, minDepth: minDepth)) {
      case EvalLookupHit(:final hit):
        stats.lichessEvalHits++;
        return recordHit(EvalChainSource.lichessEvals, hit);
      case EvalLookupShallow():
        stats.lichessEvalShallow++;
      case EvalLookupHardMiss() || EvalLookupMiss():
        stats.lichessEvalMisses++;
    }
  }

  if (localHardMiss && config.enableExtEvalSubtreeSkip) {
    mode = ExtEvalMode.skipExternal;
    stats.extEvalSubtreeSkips++;
  }

  if (mode != ExtEvalMode.skipExternal &&
      config.enableChessDbApi &&
      chessDbApi != null) {
    if (!chessDbApi.quotaRemaining) {
      stats.chessDbApiQuotaBlocked++;
    } else {
      switch (await chessDbApi.lookup(fen, minDepth: minDepth)) {
        case EvalLookupHit(:final hit):
          stats.chessDbApiHits++;
          return recordHit(EvalChainSource.chessDbApi, hit);
        case EvalLookupShallow():
          stats.chessDbApiShallow++;
        case EvalLookupHardMiss() || EvalLookupMiss():
          stats.chessDbApiMisses++;
      }
    }
  }

  if (!allowStockfishFallback) {
    return EvalChainOutcome(extEvalMode: mode);
  }

  final sf = await stockfishEval(fen, config.evalDepth);
  stats.sfSingleCalls++;
  final whiteCp = isWhiteToMove(fen) ? sf.stmCp : -sf.stmCp;
  await cacheWrite?.call(fen, whiteCp, sf.depth);

  return EvalChainOutcome(
    source: EvalChainSource.stockfish,
    whiteCp: whiteCp,
    depth: sf.depth,
    extEvalMode: mode,
  );
}
