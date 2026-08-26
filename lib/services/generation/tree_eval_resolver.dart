/// Eval provider lifecycle, DB/explorer lookups, and eval-chain resolution
/// for Phase 1 tree building.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import '../engine/stockfish_pool.dart';
import '../eval/cdbdirect_eval_provider.dart';
import '../eval/chessdb_api_provider.dart';
import '../eval/db_move_list.dart';
import '../eval/eval_chain.dart';
import '../eval/sqlite_eval_provider.dart';
import '../eval_cache.dart';
import 'fen_map.dart';
import 'generation_config.dart';

class TreeEvalResolver {
  final EvalCache evalCache = EvalCache.instance;
  SqliteEvalProvider? _localChessDb;
  CdbDirectEvalProvider? _cdbDirect;
  ChessDbApiProvider? _chessDbApi;

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
    final outcome = await resolveEvalChain(
      fen: fen,
      config: config,
      cache: evalCache,
      stats: stats,
      localChessDb: _localChessDb,
      cdbDirect: _cdbDirect,
      chessDbApi: _chessDbApi,
      allowStockfishFallback: false,
      stockfishEval: (_, _) async => (stmCp: 0, depth: 0),
      cacheWrite: (f, whiteCp, depth) async {
        cacheEvalWhite(f, whiteCp, depth);
      },
    );
    if (outcome.whiteCp != null) {
      return (outcome.whiteCp!, outcome.depth);
    }
    return null;
  }

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
