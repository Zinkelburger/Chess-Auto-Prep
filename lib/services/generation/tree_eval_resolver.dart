/// Eval provider lifecycle, DB/explorer lookups, and eval-chain resolution
/// for Phase 1 tree building.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess_core/generation/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import '../engine/stockfish_pool.dart';
import '../eval/cdbdirect_eval_provider.dart';
import '../eval/chessdb_api_provider.dart';
import '../eval/db_move_list.dart';
import '../eval/eval_chain.dart';
import '../eval/lichess_eval_provider.dart';
import '../eval/sqlite_eval_provider.dart';
import '../eval_cache.dart';
import 'fen_map.dart';
import 'generation_config.dart';

/// Owns the external eval providers for one build and answers every
/// position lookup through the shared eval chain.
class TreeEvalResolver {
  final EvalCache evalCache = EvalCache.instance;
  SqliteEvalProvider? _localChessDb;
  LichessEvalProvider? _lichessEvals;
  CdbDirectEvalProvider? _cdbDirect;
  ChessDbApiProvider? _chessDbApi;

  /// Counters for the current run. The build service installs a fresh
  /// [BuildStats] before each build, so this is set before any lookup.
  late BuildStats stats;

  ChessDbApiProvider? get chessDbApiProvider => _chessDbApi;

  /// Test seam: a move source that stands in for the whole ChessDB chain in
  /// [lookupBookMoves].  Production installs providers through
  /// [initProviders]; nothing else may set this.
  @visibleForTesting
  ExternalMoveProvider? bookMovesOverride;

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

    if (config.enableLichessEvals && config.lichessEvalsPath.isNotEmpty) {
      final provider = LichessEvalProvider(directory: config.lichessEvalsPath);
      if (await provider.init()) {
        _lichessEvals = provider;
      }
    }

    if (config.enableChessDbApi) {
      final api = ChessDbApiProvider(
        dailyQuota: config.chessDbApiDailyQuota,
        concurrency: config.chessDbApiConcurrency,
      );
      await api.init();
      _chessDbApi = api;
    }
  }

  Future<void> teardownProviders() async {
    await _localChessDb?.close();
    _localChessDb = null;
    await _cdbDirect?.close();
    _cdbDirect = null;
    await _lichessEvals?.close();
    _lichessEvals = null;
    await _chessDbApi?.flushQuota();
    _chessDbApi = null;
  }

  /// ChessDB's whole ranked move list for [fen] — local dump first, then the
  /// cloud API.  [DbMoveList.empty] when neither knows the position; the
  /// caller decides whether that ends the line or the engine takes over.
  ///
  /// Deliberately *not* part of [resolveEvalChain]: the sqlite eval database
  /// stores scores, not move lists, and the project eval cache is keyed by
  /// position rather than by fan-out, so neither has an answer to give here.
  /// One lookup returns the score of every child, which is what makes a book
  /// build cost a request per position instead of per move.
  Future<DbMoveList> lookupBookMoves(String fen, TreeBuildConfig config) async {
    final override = bookMovesOverride;
    if (override != null) return override.lookupMoves(fen);

    final direct = _cdbDirect;
    if (config.enableCdbDirect && direct != null) {
      final hit = await direct.lookupMoves(fen);
      if (hit.isNotEmpty) {
        stats.cdbDirectHits++;
        return hit;
      }
      stats.cdbDirectHardMisses++;
    }

    final api = _chessDbApi;
    if (config.enableChessDbApi && api != null) {
      if (!api.quotaRemaining) {
        stats.chessDbApiQuotaBlocked++;
      } else {
        final hit = await api.lookupMoves(fen);
        if (hit.isNotEmpty) {
          stats.chessDbApiHits++;
          return hit;
        }
        stats.chessDbApiMisses++;
      }
    }

    return DbMoveList.empty;
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
    final outcome = await _resolve(
      fen: fen,
      config: config,
      allowStockfishFallback: false,
      stockfishEval: (_, _) async => (stmCp: 0, depth: 0),
    );
    final whiteCp = outcome.whiteCp;
    return whiteCp == null ? null : (whiteCp, outcome.depth);
  }

  /// The eval chain over this resolver's providers and cache.
  Future<EvalChainOutcome> _resolve({
    required String fen,
    required TreeBuildConfig config,
    required bool allowStockfishFallback,
    required StockfishEvalFn stockfishEval,
    ExtEvalMode extEvalMode = ExtEvalMode.none,
    BuildTreeNode? canonicalNode,
  }) => resolveEvalChain(
    fen: fen,
    config: config,
    cache: evalCache,
    stats: stats,
    localChessDb: _localChessDb,
    cdbDirect: _cdbDirect,
    lichessEvals: _lichessEvals,
    chessDbApi: _chessDbApi,
    extEvalMode: extEvalMode,
    canonicalNode: canonicalNode,
    allowStockfishFallback: allowStockfishFallback,
    stockfishEval: stockfishEval,
    cacheWrite: (f, whiteCp, depth) async {
      cacheEvalWhite(f, whiteCp, depth);
    },
  );

  /// Persist an eval (white-normalized cp).  Fire-and-forget — the L1
  /// mirror inside [EvalCache] is updated synchronously, so subsequent
  /// reads hit immediately without awaiting the DB write.
  void cacheEvalWhite(String fen, int whiteCp, int depth) {
    evalCache.putEvalCpWhiteSoon(fen, whiteCp, depth);
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

    final outcome = await _resolve(
      fen: node.fen,
      config: config,
      extEvalMode: node.extEvalMode,
      canonicalNode: fenMap.getCanonical(node.fen),
      allowStockfishFallback: !dbOnly,
      stockfishEval: (f, depth) async {
        final sw = Stopwatch()..start();
        final result = await pool.evaluateFen(f, depth);
        stats.sfSingleMs += sw.elapsedMilliseconds;
        return (stmCp: result.effectiveCp, depth: depth);
      },
    );

    if (outcome.extEvalMode != node.extEvalMode) {
      node.extEvalMode = outcome.extEvalMode;
    }

    final whiteCp = outcome.whiteCp;
    if (whiteCp == null) return false;
    node.engineEvalCp = isWhiteToMove(node.fen) ? whiteCp : -whiteCp;
    return true;
  }
}
