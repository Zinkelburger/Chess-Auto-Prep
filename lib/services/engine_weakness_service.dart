/// Evaluates positions from the opening tree with Stockfish to find
/// "weaknesses" — positions the player reaches frequently that are
/// objectively bad according to the engine.
///
/// Uses [StockfishPool] for worker management with a fixed per-worker hash
/// (see [_pool.effectiveSettings.hashMb]).
library;

import 'package:flutter/foundation.dart';

import '../models/engine_weakness_result.dart';
import '../models/opening_tree.dart';
import '../utils/eval_constants.dart';
import '../utils/fen_utils.dart';
import 'engine/stockfish_pool.dart';

/// A position the player reaches often enough to be worth an engine search,
/// tagged with the colour they had in those games.
typedef _PositionToEval = ({PositionGroup group, bool playerIsWhite});

/// Engine centipawn/mate scores rewritten from White's point of view.
typedef _WhiteRelativeEval = ({int cp, int? mate});

/// The engine could not produce a single evaluation.
class EngineWeaknessException implements Exception {
  const EngineWeaknessException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EngineWeaknessService {
  EngineWeaknessService({required StockfishPool pool}) : _pool = pool;
  final StockfishPool _pool;
  bool _cancelled = false;

  int get workerCount => _pool.workerCount;

  /// How many failed positions are named in the debug log; the rest are
  /// only counted.
  static const int _maxLoggedFailures = 5;

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
  ///
  /// Throws [EngineWeaknessException] when no worker could be started or
  /// every search failed; a cancelled run returns what finished.
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
      throw const EngineWeaknessException(
        'Could not create any Stockfish workers. '
        'Is Stockfish available on this platform?',
      );
    }

    onWorkersReady?.call(_pool.workerCount, _pool.effectiveSettings.hashMb);

    final positions = [
      if (whiteTree != null)
        ..._frequentPositions(whiteTree, minOccurrences, playerIsWhite: true),
      if (blackTree != null)
        ..._frequentPositions(blackTree, minOccurrences, playerIsWhite: false),
    ];
    if (positions.isEmpty) return [];

    final total = positions.length;
    final results = <EngineWeaknessResult>[];
    final failedPositions = <String>[];
    var completed = 0;
    var failedCount = 0;

    onProgress?.call(0, total);

    Future<void> evalPosition(EvalWorker worker, _PositionToEval entry) async {
      try {
        final result = await _evaluate(worker, entry, depth);
        if (result == null) return;
        results.add(result);
        onResult?.call(result);
      } catch (e) {
        failedCount++;
        if (kDebugMode && failedPositions.length < _maxLoggedFailures) {
          final path = entry.group.primaryNode.getMovePathString();
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
      throw EngineWeaknessException(
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

  /// Every position of [tree] played in at least [minOccurrences] games.
  ///
  /// Counts are summed across transpositions: a position reached 3 times via
  /// two move orders must still qualify (a per-path count would miss it).
  static Iterable<_PositionToEval> _frequentPositions(
    OpeningTree tree,
    int minOccurrences, {
    required bool playerIsWhite,
  }) sync* {
    for (final nodes in tree.fenToNodes.values) {
      if (nodes.isEmpty) continue;
      final group = PositionGroup(nodes);
      if (group.gamesPlayed >= minOccurrences) {
        yield (group: group, playerIsWhite: playerIsWhite);
      }
    }
  }

  /// Search [entry]'s position on [worker]. Null when the run was cancelled
  /// while the search was in flight.
  Future<EngineWeaknessResult?> _evaluate(
    EvalWorker worker,
    _PositionToEval entry,
    int depth,
  ) async {
    final group = entry.group;
    final fullFen = expandFen(group.fen);
    final eval = await worker.evaluateFen(fullFen, depth);
    if (_cancelled) return null;

    final whiteEval = _whiteRelative(eval, whiteToMove: isWhiteToMove(fullFen));
    final result = EngineWeaknessResult(
      fen: group.fen,
      evalCp: whiteEval.cp,
      evalMate: whiteEval.mate,
      depth: eval.depth,
      gamesPlayed: group.gamesPlayed,
      wins: group.wins,
      losses: group.losses,
      draws: group.draws,
      winRate: group.winRate,
      movePath: group.primaryNode.getMovePathString(),
      playerIsWhite: entry.playerIsWhite,
    );

    if (kDebugMode) {
      final color = entry.playerIsWhite ? 'W' : 'B';
      debugPrint(
        '[Eval] $color ${result.evalDisplay} '
        'd${eval.depth} ${group.gamesPlayed}g '
        '${result.movePath}',
      );
    }
    return result;
  }

  /// The engine reports scores for the side to move; results are stored
  /// from White's side. A mate score is also pinned to the mate centipawn
  /// ceiling so it sorts past every non-mate eval.
  static _WhiteRelativeEval _whiteRelative(
    EvalResult eval, {
    required bool whiteToMove,
  }) {
    final mate = eval.scoreMate;
    if (mate != null) {
      final whiteMate = whiteToMove ? mate : -mate;
      return (cp: whiteMate > 0 ? kMateCpBase : -kMateCpBase, mate: whiteMate);
    }
    final cp = eval.scoreCp ?? 0;
    return (cp: whiteToMove ? cp : -cp, mate: null);
  }

  void cancel() {
    _cancelled = true;
    _pool.stopAll();
  }

  void dispose() {
    cancel();
  }
}
