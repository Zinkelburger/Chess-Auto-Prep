/// Automatic repertoire generation via DFS traversal with DB/MAIA/engine.
///
/// Supports three strategies:
///   - engineOnly: greedy best-eval move selection
///   - winRateOnly: greedy best-DB-win-rate move selection
///   - metaEval: propagated MetaEase (opponentEase) with eval guard
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:chess/chess.dart' as chess;

import '../models/engine_settings.dart';
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import '../utils/ease_utils.dart';
import 'engine/eval_worker.dart';
import 'engine/stockfish_connection_factory.dart';
import 'maia_factory.dart';
import 'probability_service.dart';

// ── Public types ─────────────────────────────────────────────────────────

enum GenerationStrategy {
  engineOnly,
  winRateOnly,
  metaEval,
}

class RepertoireGenerationConfig {
  final String startFen;
  final bool isWhiteRepertoire;
  final double cumulativeProbabilityCutoff;
  final double opponentMassTarget;
  final int maxDepthPly;
  final int engineDepth;
  final int easeDepth;
  final int engineTopK;
  final int maxCandidates;
  final int maxEvalLossCp;
  final int minEvalCpForUs;
  final int maxEvalCpForUs;
  final double metaAlpha;
  final int maiaElo;

  const RepertoireGenerationConfig({
    required this.startFen,
    required this.isWhiteRepertoire,
    this.cumulativeProbabilityCutoff = 0.001,
    this.opponentMassTarget = 0.80,
    this.maxDepthPly = 15,
    this.engineDepth = 20,
    this.easeDepth = 18,
    this.engineTopK = 3,
    this.maxCandidates = 8,
    this.maxEvalLossCp = 50,
    this.minEvalCpForUs = 0,
    this.maxEvalCpForUs = 200,
    this.metaAlpha = 0.35,
    this.maiaElo = 2100,
  });
}

class GeneratedLine {
  final List<String> movesSan;
  final double cumulativeProbability;
  final int finalEvalWhiteCp;
  final double metaEase;

  const GeneratedLine({
    required this.movesSan,
    required this.cumulativeProbability,
    required this.finalEvalWhiteCp,
    required this.metaEase,
  });
}

class GenerationProgress {
  final int nodesVisited;
  final int linesGenerated;
  final int currentDepth;
  final String message;

  const GenerationProgress({
    required this.nodesVisited,
    required this.linesGenerated,
    required this.currentDepth,
    required this.message,
  });
}

// ── Simple multi-worker pool for parallel eval ──────────────────────────

/// A lightweight pool of [EvalWorker]s that distributes `evaluateFen` calls
/// across available workers using a round-robin / first-free strategy.
class _EvalPool {
  final List<EvalWorker> _workers = [];
  int _nextWorker = 0;

  Future<void> init({required int workerCount, required int hashPerWorker}) async {
    for (int i = 0; i < workerCount; i++) {
      final conn = await StockfishConnectionFactory.create();
      if (conn == null) break;
      final w = EvalWorker(conn);
      await w.init(hashMb: hashPerWorker);
      _workers.add(w);
    }
    if (_workers.isEmpty) {
      throw Exception('Could not create any Stockfish workers.');
    }
  }

  int get workerCount => _workers.length;

  /// The first worker is used for sequential operations like MultiPV
  /// discovery which must not overlap with other eval calls.
  EvalWorker get primary => _workers[0];

  /// Get the next worker in round-robin order for parallel eval requests.
  EvalWorker _nextFree() {
    final w = _workers[_nextWorker % _workers.length];
    _nextWorker++;
    return w;
  }

  /// Evaluate a single FEN on the next available worker.
  Future<EvalResult> evaluateFen(String fen, int depth) {
    return _nextFree().evaluateFen(fen, depth);
  }

  /// Evaluate multiple FENs in parallel, distributing across all workers.
  Future<List<EvalResult>> evaluateMany(List<String> fens, int depth) async {
    if (fens.isEmpty) return const [];
    // Launch all evals concurrently; the round-robin distributes them.
    final futures = fens.map((f) => evaluateFen(f, depth)).toList();
    return Future.wait(futures);
  }

  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }
}

// ── Generation service ──────────────────────────────────────────────────

class RepertoireGenerationService {
  final ProbabilityService _probabilityService = ProbabilityService();

  // Caches keyed by FEN (or FEN|depth).
  final Map<String, int> _evalWhiteCache = {};
  final Map<String, double?> _easeCache = {};
  final Map<String, PositionProbabilities?> _dbCache = {};
  final Map<String, double> _metaEaseCache = {};

  int _nodesVisited = 0;
  int _linesGenerated = 0;

  Future<void> generate({
    required RepertoireGenerationConfig config,
    required GenerationStrategy strategy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
  }) async {
    final settings = EngineSettings();
    // Use up to half the available cores for generation, minimum 1.
    final desiredWorkers = math.max(1, settings.cores ~/ 2);
    final hashPer = settings.hashPerWorker;

    final pool = _EvalPool();
    await pool.init(workerCount: desiredWorkers, hashPerWorker: hashPer);

    _nodesVisited = 0;
    _linesGenerated = 0;
    _evalWhiteCache.clear();
    _easeCache.clear();
    _dbCache.clear();
    _metaEaseCache.clear();

    onProgress(GenerationProgress(
      nodesVisited: 0,
      linesGenerated: 0,
      currentDepth: 0,
      message: 'Spawned ${pool.workerCount} engine workers',
    ));

    try {
      await _dfsNode(
        pool: pool,
        config: config,
        strategy: strategy,
        isCancelled: isCancelled,
        onLine: onLine,
        onProgress: onProgress,
        fen: config.startFen,
        depth: 0,
        cumulativeProb: 1.0,
        lineSan: const [],
        emitLines: true,
      );
    } finally {
      pool.dispose();
    }
  }

  // ── Core DFS ────────────────────────────────────────────────────────────

  /// Returns the MetaEase value for this subtree.
  Future<double> _dfsNode({
    required _EvalPool pool,
    required RepertoireGenerationConfig config,
    required GenerationStrategy strategy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
    required String fen,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
    required bool emitLines,
  }) async {
    if (isCancelled()) return 0.0;

    // Check MetaEase cache (avoids double-traversal for metaEval).
    if (!emitLines && _metaEaseCache.containsKey(fen)) {
      return _metaEaseCache[fen]!;
    }

    _nodesVisited++;
    onProgress(GenerationProgress(
      nodesVisited: _nodesVisited,
      linesGenerated: _linesGenerated,
      currentDepth: depth,
      message: 'Exploring depth $depth',
    ));

    // Evaluate this position.
    final evalWhiteCp = await _evaluateWhiteCp(pool, fen, config.engineDepth);
    final evalForUs = _toOurPerspective(evalWhiteCp, config.isWhiteRepertoire);

    final reachedStop = depth >= config.maxDepthPly ||
        cumulativeProb < config.cumulativeProbabilityCutoff ||
        evalForUs >= config.maxEvalCpForUs ||
        evalForUs <= config.minEvalCpForUs;

    final game = chess.Chess.fromFEN(fen);
    final legalMoves = game.generate_moves();
    if (reachedStop || legalMoves.isEmpty) {
      double metaEase = 0.5;
      if (strategy == GenerationStrategy.metaEval) {
        final nodeEase = await _computeNodeEase(pool, fen, config.easeDepth, maiaElo: config.maiaElo);
        metaEase = 1.0 - (nodeEase ?? 0.5);
      }
      if (emitLines && lineSan.isNotEmpty) {
        _linesGenerated++;
        await onLine(GeneratedLine(
          movesSan: lineSan,
          cumulativeProbability: cumulativeProb,
          finalEvalWhiteCp: evalWhiteCp,
          metaEase: metaEase,
        ));
      }
      _metaEaseCache[fen] = metaEase;
      return metaEase;
    }

    final isWhiteToMove = fen.split(' ').length >= 2 && fen.split(' ')[1] == 'w';
    final isOurMove = isWhiteToMove == config.isWhiteRepertoire;

    if (isOurMove) {
      return _handleOurMove(
        pool: pool,
        config: config,
        strategy: strategy,
        isCancelled: isCancelled,
        onLine: onLine,
        onProgress: onProgress,
        fen: fen,
        depth: depth,
        cumulativeProb: cumulativeProb,
        lineSan: lineSan,
        emitLines: emitLines,
      );
    }

    return _handleOpponentMove(
      pool: pool,
      config: config,
      strategy: strategy,
      isCancelled: isCancelled,
      onLine: onLine,
      onProgress: onProgress,
      fen: fen,
      depth: depth,
      cumulativeProb: cumulativeProb,
      lineSan: lineSan,
      emitLines: emitLines,
    );
  }

  // ── Our move (decision node) ────────────────────────────────────────────

  Future<double> _handleOurMove({
    required _EvalPool pool,
    required RepertoireGenerationConfig config,
    required GenerationStrategy strategy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
    required String fen,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
    required bool emitLines,
  }) async {
    final candidates = await _buildOurCandidates(
      pool: pool,
      fen: fen,
      config: config,
    );
    if (candidates.isEmpty) return 0.0;

    // Filter candidates within maxEvalLossCp of best and above floor.
    final bestEvalForUs = candidates
        .map((c) => _toOurPerspective(c.evalWhiteCp, config.isWhiteRepertoire))
        .reduce(math.max);

    final valid = candidates.where((c) {
      final childEval = _toOurPerspective(c.evalWhiteCp, config.isWhiteRepertoire);
      return childEval >= bestEvalForUs - config.maxEvalLossCp &&
          childEval >= config.minEvalCpForUs;
    }).toList();

    final candidatePool = valid.isNotEmpty ? valid : candidates;

    // Select move based on strategy.
    _CandidateMove? selected;

    if (strategy == GenerationStrategy.engineOnly) {
      // FIX: compare in our-perspective, not raw White cp.
      selected = candidatePool.reduce((a, b) {
        final aEval = _toOurPerspective(a.evalWhiteCp, config.isWhiteRepertoire);
        final bEval = _toOurPerspective(b.evalWhiteCp, config.isWhiteRepertoire);
        return aEval >= bEval ? a : b;
      });
    } else if (strategy == GenerationStrategy.winRateOnly) {
      selected = candidatePool.reduce((a, b) {
        if (a.winRate == b.winRate) {
          // FIX: tie-break in our-perspective.
          final aEval = _toOurPerspective(a.evalWhiteCp, config.isWhiteRepertoire);
          final bEval = _toOurPerspective(b.evalWhiteCp, config.isWhiteRepertoire);
          return aEval >= bEval ? a : b;
        }
        return a.winRate >= b.winRate ? a : b;
      });
    } else {
      // metaEval: explore each candidate subtree to get MetaEase,
      // pick highest. Uses _metaEaseCache to avoid double-traversal.
      double bestMeta = -1e9;
      for (final c in candidatePool) {
        if (isCancelled()) break;
        final v = await _dfsNode(
          pool: pool,
          config: config,
          strategy: strategy,
          isCancelled: isCancelled,
          onLine: onLine,
          onProgress: onProgress,
          fen: c.childFen,
          depth: depth + 1,
          cumulativeProb: cumulativeProb,
          lineSan: [...lineSan, c.san],
          emitLines: false, // exploration pass
        );
        if (v > bestMeta) {
          bestMeta = v;
          selected = c;
        }
      }
    }

    if (selected == null) return 0.0;

    // Final traversal of selected branch to emit lines.
    final result = await _dfsNode(
      pool: pool,
      config: config,
      strategy: strategy,
      isCancelled: isCancelled,
      onLine: onLine,
      onProgress: onProgress,
      fen: selected.childFen,
      depth: depth + 1,
      cumulativeProb: cumulativeProb,
      lineSan: [...lineSan, selected.san],
      emitLines: emitLines,
    );

    _metaEaseCache[fen] = result;
    return result;
  }

  // ── Opponent move (chance node) ─────────────────────────────────────────

  Future<double> _handleOpponentMove({
    required _EvalPool pool,
    required RepertoireGenerationConfig config,
    required GenerationStrategy strategy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
    required String fen,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
    required bool emitLines,
  }) async {
    final oppMoves = await _getOpponentMoves(
      fen: fen,
      massTarget: config.opponentMassTarget,
      maiaElo: config.maiaElo,
    );
    if (oppMoves.isEmpty) return 0.0;

    // FIX: renormalize probabilities to sum to 1.0.
    final probSum = oppMoves.fold<double>(0.0, (s, m) => s + m.probability);
    final normalizedMoves = probSum > 0
        ? oppMoves.map((m) => _ProbMove(
              uci: m.uci,
              probability: m.probability / probSum,
            )).toList()
        : oppMoves;

    // Compute opponentEase only for metaEval strategy.
    double opponentEase = 0.5;
    if (strategy == GenerationStrategy.metaEval) {
      final nodeEase = await _computeNodeEase(pool, fen, config.easeDepth, maiaElo: config.maiaElo);
      opponentEase = 1.0 - (nodeEase ?? 0.5);
    }

    // Evaluate all opponent child positions in parallel.
    final childFens = <String>[];
    final childSans = <String>[];
    final validIndices = <int>[];
    for (int i = 0; i < normalizedMoves.length; i++) {
      final childFen = playUciMove(fen, normalizedMoves[i].uci);
      if (childFen == null) continue;
      childFens.add(childFen);
      childSans.add(uciToSan(fen, normalizedMoves[i].uci));
      validIndices.add(i);
    }

    double future = 0.0;
    for (int j = 0; j < childFens.length; j++) {
      if (isCancelled()) break;

      final idx = validIndices[j];
      final prob = normalizedMoves[idx].probability;

      final v = await _dfsNode(
        pool: pool,
        config: config,
        strategy: strategy,
        isCancelled: isCancelled,
        onLine: onLine,
        onProgress: onProgress,
        fen: childFens[j],
        depth: depth + 1,
        cumulativeProb: cumulativeProb * oppMoves[idx].probability,
        lineSan: [...lineSan, childSans[j]],
        emitLines: emitLines,
      );
      future += prob * v;
    }

    final result = strategy == GenerationStrategy.metaEval
        ? config.metaAlpha * opponentEase + (1.0 - config.metaAlpha) * future
        : future;

    _metaEaseCache[fen] = result;
    return result;
  }

  // ── Candidate building ─────────────────────────────────────────────────

  Future<List<_CandidateMove>> _buildOurCandidates({
    required _EvalPool pool,
    required String fen,
    required RepertoireGenerationConfig config,
  }) async {
    final isWhiteToMove = fen.split(' ')[1] == 'w';

    // MultiPV discovery must run on a single worker (cannot overlap).
    final discovery = await pool.primary.runDiscovery(
      fen,
      config.engineDepth,
      config.engineTopK,
      isWhiteToMove,
    );

    final engineUcis = discovery.lines
        .map((l) => l.moveUci)
        .where((u) => u.isNotEmpty)
        .take(config.engineTopK)
        .toList();

    final likely = await _getLikelyMovesForUs(fen, maiaElo: config.maiaElo);
    final merged = <String>{...engineUcis, ...likely};
    final selectedUcis = merged.take(config.maxCandidates).toList();

    // Compute child FENs.
    final childFens = <String>[];
    final validUcis = <String>[];
    for (final uci in selectedUcis) {
      final childFen = playUciMove(fen, uci);
      if (childFen == null) continue;
      childFens.add(childFen);
      validUcis.add(uci);
    }

    // Evaluate all candidates in parallel across workers.
    final evalResults = await pool.evaluateMany(childFens, config.engineDepth);
    final parentIsWhiteToMove = isWhiteToMove;

    final dbData = await _getDbData(fen);
    final byUci = <String, MoveProbability>{};
    if (dbData != null) {
      for (final m in dbData.moves) {
        if (m.uci.isNotEmpty) byUci[m.uci] = m;
      }
    }

    final out = <_CandidateMove>[];
    for (int i = 0; i < validUcis.length; i++) {
      final uci = validUcis[i];
      final eval = evalResults[i];
      final evalWhiteCp = parentIsWhiteToMove ? -eval.effectiveCp : eval.effectiveCp;

      // Cache for later reuse.
      _evalWhiteCache['${childFens[i]}|${config.engineDepth}'] = evalWhiteCp;

      final san = uciToSan(fen, uci);
      final dbMove = byUci[uci];
      final winRate = dbMove == null
          ? 0.5
          : _dbWinRateForUs(dbMove: dbMove, isWhiteRepertoire: config.isWhiteRepertoire);

      out.add(_CandidateMove(
        uci: uci,
        san: san,
        childFen: childFens[i],
        evalWhiteCp: evalWhiteCp,
        winRate: winRate,
      ));
    }
    return out;
  }

  // ── Move sources ───────────────────────────────────────────────────────

  Future<List<String>> _getLikelyMovesForUs(String fen, {required int maiaElo}) async {
    final db = await _getDbData(fen);
    if (db != null && db.moves.isNotEmpty) {
      final sorted = db.moves.toList()
        ..sort((a, b) => b.probability.compareTo(a.probability));
      return sorted
          .where((m) => m.uci.isNotEmpty && m.probability >= 2.0)
          .map((m) => m.uci)
          .toList();
    }

    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      return const [];
    }
    final maia = await MaiaFactory.instance!.evaluate(fen, maiaElo);
    final sorted = maia.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .where((e) => e.value >= 0.02)
        .map((e) => e.key)
        .toList();
  }

  Future<List<_ProbMove>> _getOpponentMoves({
    required String fen,
    required double massTarget,
    required int maiaElo,
  }) async {
    final out = <_ProbMove>[];
    final db = await _getDbData(fen);
    if (db != null && db.moves.isNotEmpty) {
      final sorted = db.moves.toList()
        ..sort((a, b) => b.probability.compareTo(a.probability));
      double acc = 0.0;
      for (final m in sorted) {
        if (m.uci.isEmpty) continue;
        final p = m.probability / 100.0;
        if (p < 0.01) continue;
        out.add(_ProbMove(uci: m.uci, probability: p));
        acc += p;
        if (acc >= massTarget) break;
      }
      if (out.isNotEmpty) return out;
    }

    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      return out;
    }
    final maia = await MaiaFactory.instance!.evaluate(fen, maiaElo);
    if (maia.isEmpty) return out;
    final sorted = maia.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    double acc = 0.0;
    for (final e in sorted) {
      if (e.value < 0.01) continue;
      out.add(_ProbMove(uci: e.key, probability: e.value));
      acc += e.value;
      if (acc >= massTarget) break;
    }
    return out;
  }

  // ── DB + eval helpers ─────────────────────────────────────────────────

  Future<PositionProbabilities?> _getDbData(String fen) async {
    if (_dbCache.containsKey(fen)) return _dbCache[fen];
    final data = await _probabilityService.getProbabilitiesForFen(fen);
    _dbCache[fen] = data;
    return data;
  }

  Future<int> _evaluateWhiteCp(_EvalPool pool, String fen, int depth) async {
    final key = '$fen|$depth';
    final cached = _evalWhiteCache[key];
    if (cached != null) return cached;

    final eval = await pool.evaluateFen(fen, depth);
    final isWhiteToMove = fen.split(' ')[1] == 'w';
    final whiteCp = isWhiteToMove ? eval.effectiveCp : -eval.effectiveCp;
    _evalWhiteCache[key] = whiteCp;
    return whiteCp;
  }

  int _toOurPerspective(int whiteCp, bool isWhiteRepertoire) =>
      isWhiteRepertoire ? whiteCp : -whiteCp;

  double _dbWinRateForUs({
    required MoveProbability dbMove,
    required bool isWhiteRepertoire,
  }) {
    final total = dbMove.total;
    if (total <= 0) return 0.5;
    final ourWins = isWhiteRepertoire ? dbMove.white : dbMove.black;
    return (ourWins + 0.5 * dbMove.draws) / total;
  }

  // ── Ease computation (DB→MAIA fallback, parallel eval) ────────────────

  Future<double?> _computeNodeEase(
    _EvalPool pool,
    String fen,
    int depth, {
    required int maiaElo,
  }) async {
    final cacheKey = '$fen|$depth';
    if (_easeCache.containsKey(cacheKey)) {
      return _easeCache[cacheKey];
    }

    final candidates = <MapEntry<String, double>>[];
    final dbData = await _getDbData(fen);
    if (dbData != null && dbData.moves.isNotEmpty) {
      final sortedDb = dbData.moves.toList()
        ..sort((a, b) => b.probability.compareTo(a.probability));

      double cumulativeProb = 0.0;
      for (final move in sortedDb) {
        if (move.uci.isEmpty) continue;
        final prob = move.probability / 100.0;
        if (prob < 0.01) continue;
        candidates.add(MapEntry(move.uci, prob));
        cumulativeProb += prob;
        if (cumulativeProb > 0.90) break;
      }

      final hasReliableDbMass = candidates.isNotEmpty &&
          candidates.every((entry) {
            for (final move in sortedDb) {
              if (move.uci == entry.key) return move.total > 50;
            }
            return false;
          });
      if (!hasReliableDbMass) {
        candidates.clear();
      }
    }

    if (candidates.isEmpty) {
      if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
        _easeCache[cacheKey] = null;
        return null;
      }
      final maiaProbs = await MaiaFactory.instance!.evaluate(fen, maiaElo);
      if (maiaProbs.isEmpty) {
        _easeCache[cacheKey] = null;
        return null;
      }

      final sortedMaia = maiaProbs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      double cumulativeProb = 0.0;
      for (final entry in sortedMaia) {
        if (entry.value < 0.01) continue;
        candidates.add(entry);
        cumulativeProb += entry.value;
        if (cumulativeProb > 0.90) break;
      }
    }

    if (candidates.isEmpty) {
      _easeCache[cacheKey] = null;
      return null;
    }

    // Build child FENs and evaluate in parallel.
    final childFens = <String>[];
    final validCandidates = <MapEntry<String, double>>[];
    for (final entry in candidates) {
      final nextFen = playUciMove(fen, entry.key);
      if (nextFen == null) continue;
      childFens.add(nextFen);
      validCandidates.add(entry);
    }

    if (childFens.isEmpty) {
      _easeCache[cacheKey] = null;
      return null;
    }

    final evalResults = await pool.evaluateMany(childFens, depth);

    int bestForMover = -100000;
    final evalByIdx = <int, int>{};
    for (int i = 0; i < evalResults.length; i++) {
      final forMover = -evalResults[i].effectiveCp;
      evalByIdx[i] = forMover;
      bestForMover = math.max(bestForMover, forMover);
    }

    final maxQ = scoreToQ(bestForMover);
    double sumWeightedRegret = 0.0;
    for (int i = 0; i < validCandidates.length; i++) {
      final score = evalByIdx[i];
      if (score == null) continue;
      final prob = validCandidates[i].value;
      final qVal = scoreToQ(score);
      final regret = math.max(0.0, maxQ - qVal);
      sumWeightedRegret += math.pow(prob, kEaseBeta) * regret;
    }

    final ease = 1.0 - math.pow(sumWeightedRegret / 2, kEaseAlpha);
    _easeCache[cacheKey] = ease;
    return ease;
  }
}

// ── Internal data types ─────────────────────────────────────────────────

class _ProbMove {
  final String uci;
  final double probability;

  const _ProbMove({required this.uci, required this.probability});
}

class _CandidateMove {
  final String uci;
  final String san;
  final String childFen;
  final int evalWhiteCp;
  final double winRate;

  const _CandidateMove({
    required this.uci,
    required this.san,
    required this.childFen,
    required this.evalWhiteCp,
    required this.winRate,
  });
}
