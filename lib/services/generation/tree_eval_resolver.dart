/// Eval provider lifecycle, DB/explorer lookups, and eval-chain resolution
/// for Phase 1 tree building.
library;

import 'dart:async';

import '../../models/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import '../engine/stockfish_pool.dart';
import '../eval/cdbdirect_eval_provider.dart';
import '../eval/chessdb_api_provider.dart';
import '../eval/eval_chain.dart';
import '../eval/sqlite_eval_provider.dart';
import '../eval_cache.dart';
import '../probability_service.dart';
import 'fen_map.dart';
import 'generation_config.dart';

class TreeEvalResolver {
  final EvalCache evalCache = EvalCache.instance;
  final Map<String, ExplorerResponse?> _dbCache = {};
  final ProbabilityService _probabilityService = ProbabilityService.instance;

  SqliteEvalProvider? _localChessDb;
  CdbDirectEvalProvider? _cdbDirect;
  ChessDbApiProvider? _chessDbApi;

  late BuildStats stats;

  ChessDbApiProvider? get chessDbApiProvider => _chessDbApi;

  void reset() {
    _dbCache.clear();
  }

  Future<void> initProviders(TreeBuildConfig config) async {
    await teardownProviders();

    await CdbDirectEvalProvider.probeAvailability();
    if (config.enableCdbDirect &&
        config.cdbDirectPath.isNotEmpty &&
        CdbDirectEvalProvider.isAvailable) {
      final provider = CdbDirectEvalProvider(path: config.cdbDirectPath);
      if (await provider.init()) {
        _cdbDirect = provider;
      }
    }

    if (config.enableLocalChessDb && config.localChessDbPath.isNotEmpty) {
      final provider = SqliteEvalProvider(path: config.localChessDbPath);
      if (await provider.init()) {
        _localChessDb = provider;
      }
    }

    if (config.enableChessDbApi) {
      _chessDbApi = ChessDbApiProvider(
        dailyQuota: config.chessDbApiDailyQuota,
        concurrency: config.chessDbApiConcurrency,
      );
      await _chessDbApi!.init();
    }
  }

  Future<void> teardownProviders() async {
    await _localChessDb?.close();
    _localChessDb = null;
    await _cdbDirect?.close();
    _cdbDirect = null;
    if (_chessDbApi != null) {
      await _chessDbApi!.flushQuota();
      _chessDbApi = null;
    }
  }

  /// DB-chain lookup returning white-normalized cp, or null on miss.
  ///
  /// Delegates to [resolveEvalChain] with Stockfish fallback disabled so the
  /// full chain (cache, transposition, cdbDirect, local, API) is traversed
  /// consistently, including subtree-skip and stat tracking.
  Future<(int cp, int depth)?> lookupDbEvalWhite(
    String fen,
    TreeBuildConfig config,
  ) async {
    final outcome = await resolveEvalChain(
      fen: fen,
      config: config,
      cache: evalCache,
      stats: stats,
      localChessDb: _localChessDb,
      cdbDirect: _cdbDirect,
      chessDbApi: _chessDbApi,
      allowStockfishFallback: false,
      stockfishEval: (_, __) async => (stmCp: 0, depth: 0),
      cacheWrite: (f, whiteCp, depth) async {
        cacheEvalWhite(f, whiteCp, depth);
      },
    );
    if (outcome.whiteCp != null) {
      return (outcome.whiteCp!, outcome.depth);
    }
    return null;
  }

  Future<ExplorerResponse?> getDbData(
    String fen,
    TreeBuildConfig config,
  ) async {
    final cacheKey = '${config.useMasters ? "m" : "l"}|$fen';
    if (_dbCache.containsKey(cacheKey)) {
      stats.dbExplorerHits++;
      return _dbCache[cacheKey];
    }
    stats.dbExplorerMisses++;
    stats.lichessQueries++;
    final data = await _probabilityService.getProbabilitiesForFen(
      fen,
      speeds: config.speeds,
      ratings: config.ratingRange,
      useMasters: config.useMasters,
    );
    _dbCache[cacheKey] = data;
    return data;
  }

  /// Persist an eval (white-normalized cp).  Fire-and-forget — the L1
  /// mirror inside [EvalCache] is updated synchronously, so subsequent
  /// reads hit immediately without awaiting the DB write.
  void cacheEvalWhite(String fen, int whiteCp, int depth) {
    unawaited(evalCache.putEvalCpWhite(fen, whiteCp, depth));
  }

  /// Ensure eval on [node]. Returns true when an eval was resolved.
  Future<bool> ensureEval(
    BuildTreeNode node,
    TreeBuildConfig config, {
    required FenMap fenMap,
    required StockfishPool pool,
    bool dbOnly = false,
  }) async {
    if (node.hasEngineEval) return true;

    final outcome = await resolveEvalChain(
      fen: node.fen,
      config: config,
      cache: evalCache,
      stats: stats,
      localChessDb: _localChessDb,
      cdbDirect: _cdbDirect,
      chessDbApi: _chessDbApi,
      extEvalMode: node.extEvalMode,
      canonicalNode: fenMap.getCanonical(node.fen),
      allowStockfishFallback: !dbOnly,
      stockfishEval: (f, depth) async {
        final sw = Stopwatch()..start();
        final result = await pool.evaluateFen(f, depth);
        stats.sfSingleMs += sw.elapsedMilliseconds;
        return (stmCp: result.effectiveCp, depth: depth);
      },
      cacheWrite: (f, whiteCp, depth) async {
        cacheEvalWhite(f, whiteCp, depth);
      },
    );

    if (outcome.extEvalMode != node.extEvalMode) {
      node.extEvalMode = outcome.extEvalMode;
    }

    if (outcome.whiteCp != null) {
      final isWhiteStm = isWhiteToMove(node.fen);
      node.engineEvalCp = isWhiteStm ? outcome.whiteCp! : -outcome.whiteCp!;
      return true;
    }
    return false;
  }
}
