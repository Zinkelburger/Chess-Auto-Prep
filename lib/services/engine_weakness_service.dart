/// Evaluates positions from the opening tree with Stockfish to find
/// "weaknesses" — positions the player reaches frequently that are
/// objectively bad according to the engine.
///
/// Uses the same resource-budgeting as MoveAnalysisPool: PoolResourceBudget
/// computes worker count and per-worker hash from live RAM headroom.
library;

import 'package:flutter/foundation.dart';

import '../models/engine_settings.dart';
import '../models/engine_weakness_result.dart';
import '../models/opening_tree.dart';
import '../utils/fen_utils.dart';
import '../utils/system_info.dart';
import 'engine/eval_worker.dart';
import 'engine/stockfish_connection_factory.dart';
import 'pool_resource_budget.dart';

class _PositionToEval {
  final OpeningTreeNode node;
  final bool playerIsWhite;
  _PositionToEval(this.node, this.playerIsWhite);
}

class EngineWeaknessService {
  final List<EvalWorker> _workers = [];
  bool _cancelled = false;

  int get workerCount => _workers.length;
  int _hashPerWorkerMb = 0;
  int get hashPerWorkerMb => _hashPerWorkerMb;

  Future<void> _initPool({
    required int maxWorkers,
    required int maxLoadPercent,
  }) async {
    if (_workers.isNotEmpty) return;

    final settings = EngineSettings();
    final load = maxLoadPercent.toDouble();

    final systemLoad = getSystemLoad();
    final system = systemLoad != null
        ? SystemSnapshot(
            totalRamMb: systemLoad.totalRamMb,
            freeRamMb: systemLoad.freeRamMb,
            logicalCores: systemLoad.logicalCores,
          )
        : SystemSnapshot(
            totalRamMb: EngineSettings.systemRamMb,
            freeRamMb: EngineSettings.systemRamMb,
            logicalCores: EngineSettings.systemCores,
          );

    final budget = PoolResourceBudget.compute(
      system: system,
      maxLoadPercent: load,
      maxWorkers: maxWorkers,
      hashCeilingMb: settings.hashPerWorker,
    );

    final targetCount = budget.workerCapacity;
    _hashPerWorkerMb = budget.hashPerWorkerMb;

    for (int i = 0; i < targetCount; i++) {
      final conn = await StockfishConnectionFactory.create();
      if (conn == null) break;
      final w = EvalWorker(conn);
      await w.init(hashMb: _hashPerWorkerMb);
      _workers.add(w);
    }

    if (_workers.isEmpty) {
      throw Exception(
        'Could not create any Stockfish workers. '
        'Is Stockfish available on this platform?',
      );
    }
  }

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
    int? maxWorkers,
    int? maxLoadPercent,
    void Function(int completed, int total)? onProgress,
    void Function(int workerCount, int hashMb)? onWorkersReady,
  }) async {
    _cancelled = false;

    final settings = EngineSettings();
    await _initPool(
      maxWorkers: maxWorkers ?? settings.cores,
      maxLoadPercent: maxLoadPercent ?? settings.maxSystemLoad,
    );

    onWorkersReady?.call(_workers.length, _hashPerWorkerMb);

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

    Future<void> workerLoop(EvalWorker worker) async {
      while (!_cancelled) {
        final idx = nextIndex++;
        if (idx >= positions.length) break;

        final entry = positions[idx];
        final node = entry.node;
        final fullFen = expandFen(node.fen);

        try {
          final eval = await worker.evaluateFen(fullFen, depth);
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
        } catch (_) {
          // Skip positions that fail to evaluate.
        }

        completed++;
        onProgress?.call(completed, total);
      }
    }

    await Future.wait(_workers.map((w) => workerLoop(w)));

    return results;
  }

  void cancel() {
    _cancelled = true;
    for (final w in _workers) {
      w.stop();
    }
  }

  void dispose() {
    cancel();
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }
}
