/// Shared 3-phase eval resolution (cache → local → API → Stockfish).
library;

import '../../models/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import '../eval_cache.dart';
import '../generation/generation_config.dart';
import 'chessdb_api_provider.dart';
import 'external_eval_provider.dart';
import 'sqlite_eval_provider.dart';

enum EvalChainSource {
  transposition,
  projectCache,
  cdbDirect,
  localChessDb,
  chessDbApi,
  stockfish,
}

class EvalChainOutcome {
  final EvalChainSource? source;
  final int? whiteCp;
  final int depth;
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
/// Returns [EvalChainOutcome] with [whiteCp] set when a source succeeds.
/// [stockfishEval] is invoked only when earlier sources miss.
Future<EvalChainOutcome> resolveEvalChain({
  required String fen,
  required TreeBuildConfig config,
  required EvalCache cache,
  required BuildStats stats,
  SqliteEvalProvider? localChessDb,
  ExternalEvalProvider? cdbDirect,
  ExternalEvalProvider? localEvalProvider,
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

  if (canonicalNode != null && canonicalNode.hasEngineEval) {
    stats.transpositionEvalHits++;
    final isWhiteStm = isWhiteToMove(fen);
    final whiteCp = isWhiteStm
        ? canonicalNode.engineEvalCp!
        : -canonicalNode.engineEvalCp!;
    return EvalChainOutcome(
      source: EvalChainSource.transposition,
      whiteCp: whiteCp,
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

  var localHardMiss = false;
  var localHit = false;

  if (mode != ExtEvalMode.skipExternal &&
      config.enableCdbDirect &&
      cdbDirect != null) {
    final cdb = await cdbDirect.lookup(fen, minDepth: minDepth);
    if (cdb.isHit) {
      stats.cdbDirectHits++;
      localHit = true;
      return recordHit(EvalChainSource.cdbDirect, cdb.hit!);
    }
    if (cdb.shallow) {
      stats.cdbDirectShallow++;
    } else if (cdb.hardMiss) {
      stats.cdbDirectHardMisses++;
      localHardMiss = true;
    } else {
      stats.cdbDirectMisses++;
    }
  }

  if (mode != ExtEvalMode.skipExternal &&
      config.enableLocalChessDb &&
      (localChessDb != null || localEvalProvider != null)) {
    final localSource = localEvalProvider ?? localChessDb!;
    final local = await localSource.lookup(fen, minDepth: minDepth);
    if (local.isHit) {
      stats.localChessDbHits++;
      localHit = true;
      return recordHit(EvalChainSource.localChessDb, local.hit!);
    }
    if (local.shallow) {
      stats.localChessDbShallow++;
    } else if (local.hardMiss) {
      stats.localChessDbHardMisses++;
      localHardMiss = true;
    } else {
      stats.localChessDbMisses++;
    }
  }

  if (localHardMiss && !localHit && config.enableExtEvalSubtreeSkip) {
    mode = ExtEvalMode.skipExternal;
    stats.extEvalSubtreeSkips++;
  }

  if (mode != ExtEvalMode.skipExternal &&
      config.enableChessDbApi &&
      chessDbApi != null) {
    if (!chessDbApi.quotaRemaining) {
      stats.chessDbApiQuotaBlocked++;
    } else {
      final api = await chessDbApi.lookup(fen, minDepth: minDepth);
      if (api.isHit) {
        stats.chessDbApiHits++;
        return recordHit(EvalChainSource.chessDbApi, api.hit!);
      }
      if (api.shallow) {
        stats.chessDbApiShallow++;
      } else {
        stats.chessDbApiMisses++;
      }
    }
  }

  if (!allowStockfishFallback) {
    return EvalChainOutcome(extEvalMode: mode);
  }

  final sf = await stockfishEval(fen, config.evalDepth);
  stats.sfSingleCalls++;
  final isWhiteStm = isWhiteToMove(fen);
  final whiteCp = isWhiteStm ? sf.stmCp : -sf.stmCp;
  await cacheWrite?.call(fen, whiteCp, sf.depth);

  return EvalChainOutcome(
    source: EvalChainSource.stockfish,
    whiteCp: whiteCp,
    depth: sf.depth,
    extEvalMode: mode,
  );
}
