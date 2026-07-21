/// Evaluates positions from the opening tree with Stockfish to find
/// "weaknesses" — positions the player reaches frequently that are
/// objectively bad according to the engine.
///
/// Uses [StockfishPool] for worker management with a fixed per-worker hash
/// (see [kPoolHashPerWorkerMb]).
library;

import 'package:flutter/foundation.dart';

import '../models/engine_weakness_result.dart';
import '../models/opening_tree.dart';
import '../utils/eval_constants.dart';
import '../utils/fen_utils.dart';
import 'engine/stockfish_pool.dart';

class _PositionToEval {
  final PositionGroup group;
  final bool playerIsWhite;
  _PositionToEval(this.group, this.playerIsWhite);
}

class EngineWeaknessService {
  final StockfishPool _pool = StockfishPool.instance;
  bool _cancelled = false;

  int get workerCount => _pool.workerCount;

  /// Evaluate every unique position in the given trees that appears in
  /// >= [minOccurrences] games (summed across transpositions), at the
  /// given [depth].
  ///
  /// Accepts separate trees for the player's White and Black games.
  /// Returns results for ALL evaluated positions — the caller filters
  /// by eval threshold.
  ///
  /// [onResult] streams each result as its position finishes (in completion
  /// order, not input order), firing before the matching [onProgress] tick.
  Future<List<EngineWeaknessResult>> analyze({
    OpeningTree? whiteTree,
    OpeningTree? blackTree,
    int minOccurrences = 3,
    int depth = 20,
    void Function(EngineWeaknessResult result)? onResult,
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
        // Sum across transpositions: a position reached 3 times via two
        // move orders must still qualify (a per-path count would miss it).
        final group = PositionGroup(nodes);
        if (group.gamesPlayed >= minOccurrences) {
          positions.add(_PositionToEval(group, isWhite));
        }
      }
    }

    if (whiteTree != null) collectFrom(whiteTree, true);
    if (blackTree != null) collectFrom(blackTree, false);

    if (positions.isEmpty) return [];

    final total = positions.length;
    final results = <EngineWeaknessResult>[];
    final failedPositions = <String>[];
    int completed = 0;
    int failedCount = 0;

    onProgress?.call(0, total);

    Future<void> evalPosition(EvalWorker worker, _PositionToEval entry) async {
      final group = entry.group;
      final fullFen = expandFen(group.fen);

      try {
        final eval = await worker.evaluateFen(fullFen, depth);
        if (_cancelled) return;

        final whiteToMove = isWhiteToMove(fullFen);

        int evalWhiteCp;
        int? evalWhiteMate;

        if (eval.scoreMate != null) {
          evalWhiteMate = whiteToMove ? eval.scoreMate! : -eval.scoreMate!;
          evalWhiteCp = evalWhiteMate > 0 ? kMateCpBase : -kMateCpBase;
        } else {
          evalWhiteCp = whiteToMove
              ? (eval.scoreCp ?? 0)
              : -(eval.scoreCp ?? 0);
        }

        final result = EngineWeaknessResult(
          fen: group.fen,
          evalCp: evalWhiteCp,
          evalMate: evalWhiteMate,
          depth: eval.depth,
          gamesPlayed: group.gamesPlayed,
          wins: group.wins,
          losses: group.losses,
          draws: group.draws,
          winRate: group.winRate,
          movePath: group.primaryNode.getMovePathString(),
          playerIsWhite: entry.playerIsWhite,
        );
        results.add(result);
        onResult?.call(result);

        if (kDebugMode) {
          final color = entry.playerIsWhite ? 'W' : 'B';
          debugPrint(
            '[Eval] $color ${result.evalDisplay} '
            'd${eval.depth} ${group.gamesPlayed}g '
            '${result.movePath}',
          );
        }
      } catch (e) {
        failedCount++;
        if (kDebugMode && failedPositions.length < 5) {
          final path = group.primaryNode.getMovePathString();
          failedPositions.add(path);
          debugPrint('[Eval] Failed to evaluate $path: $e');
        }
      }

      completed++;
      onProgress?.call(completed, total);
    }

    await _pool.forEachParallel<_PositionToEval>(
      positions,
      evalPosition,
      stopWhen: () => _cancelled,
    );

    if (!_cancelled && results.isEmpty && failedCount > 0) {
      throw Exception(
        'Engine evaluation failed for all $failedCount positions.',
      );
    }
    if (kDebugMode && failedCount > 0) {
      debugPrint(
        '[Eval] Failed on $failedCount/$total positions'
        '${failedPositions.isEmpty ? '' : ' (${failedPositions.join(', ')})'}',
      );
    }

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
