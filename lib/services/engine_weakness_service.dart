/// Evaluates positions from the opening tree with Stockfish to find
/// "weaknesses" — positions the player reaches frequently that are
/// objectively bad according to the engine.
///
/// Uses [StockfishPool] for worker management with fixed 64 MB hash
/// per worker.
library;

import 'package:flutter/foundation.dart';

import '../models/engine_weakness_result.dart';
import '../models/opening_tree.dart';
import '../utils/fen_utils.dart';
import 'engine/stockfish_pool.dart';

class _PositionToEval {
  final OpeningTreeNode node;
  final bool playerIsWhite;
  _PositionToEval(this.node, this.playerIsWhite);
}

class EngineWeaknessService {
  final StockfishPool _pool = StockfishPool();
  bool _cancelled = false;

  int get workerCount => _pool.workerCount;

  /// Evaluate every unique position in the given trees that appears in
  /// >= [minOccurrences] games, at the given [depth].
  ///
  /// Accepts separate trees for the player's White and Black games.
  /// Returns results for ALL evaluated positions — the caller filters
  /// by eval threshold.
  Future<List<EngineWeaknessResult>> analyze({
    OpeningTree? whiteTree,
    OpeningTree? blackTree,
    int minOccurrences = 3,
    int depth = 20,
    void Function(int completed, int total)? onProgress,
    void Function(int workerCount, int hashMb)? onWorkersReady,
  }) async {
    _cancelled = false;

    await _pool.ensureWorkers();

    if (_pool.workerCount == 0) {
      throw Exception(
        'Could not create any Stockfish workers. '
        'Is Stockfish available on this platform?',
      );
    }

    onWorkersReady?.call(_pool.workerCount, kPoolHashPerWorkerMb);

    final positions = <_PositionToEval>[];

    void collectFrom(OpeningTree tree, bool isWhite) {
      for (final nodes in tree.fenToNodes.values) {
        if (nodes.isEmpty) continue;
        final best =
            nodes.reduce((a, b) => a.gamesPlayed >= b.gamesPlayed ? a : b);
        if (best.gamesPlayed >= minOccurrences) {
          positions.add(_PositionToEval(best, isWhite));
        }
      }
    }

    if (whiteTree != null) collectFrom(whiteTree, true);
    if (blackTree != null) collectFrom(blackTree, false);

    if (positions.isEmpty) return [];

    final total = positions.length;
    final results = <EngineWeaknessResult>[];
    int nextIndex = 0;
    int completed = 0;

    onProgress?.call(0, total);

    Future<void> evalPosition(int idx) async {
      final entry = positions[idx];
      final node = entry.node;
      final fullFen = expandFen(node.fen);

      try {
        final eval = await _pool.evaluateFen(fullFen, depth);
        if (_cancelled) return;

        final fenParts = fullFen.split(' ');
        final isWhiteToMove =
            fenParts.length >= 2 && fenParts[1] == 'w';

        int evalWhiteCp;
        int? evalWhiteMate;

        if (eval.scoreMate != null) {
          evalWhiteMate =
              isWhiteToMove ? eval.scoreMate! : -eval.scoreMate!;
          evalWhiteCp = evalWhiteMate > 0 ? 10000 : -10000;
        } else {
          evalWhiteCp = isWhiteToMove
              ? (eval.scoreCp ?? 0)
              : -(eval.scoreCp ?? 0);
        }

        final result = EngineWeaknessResult(
          fen: node.fen,
          evalCp: evalWhiteCp,
          evalMate: evalWhiteMate,
          depth: eval.depth,
          gamesPlayed: node.gamesPlayed,
          wins: node.wins,
          losses: node.losses,
          draws: node.draws,
          winRate: node.winRate,
          movePath: node.getMovePathString(),
          playerIsWhite: entry.playerIsWhite,
        );
        results.add(result);

        if (kDebugMode) {
          final color = entry.playerIsWhite ? 'W' : 'B';
          debugPrint('[Eval] $color ${result.evalDisplay} '
              'd${eval.depth} ${node.gamesPlayed}g '
              '${node.getMovePathString()}');
        }
      } catch (_) {}

      completed++;
      onProgress?.call(completed, total);
    }

    final futures = <Future<void>>[];
    while (!_cancelled && nextIndex < positions.length) {
      final idx = nextIndex++;
      futures.add(evalPosition(idx));
    }
    await Future.wait(futures);

    return results;
  }

  void cancel() {
    _cancelled = true;
    _pool.stopAll();
  }

  void dispose() {
    cancel();
  }
}
