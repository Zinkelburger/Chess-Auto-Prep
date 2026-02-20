/// Automatic repertoire generation via DFS traversal.
///
/// Supports three strategies (see [GenerationStrategy]):
///   - **winRateOnly** — Pure Lichess Explorer DB lookups.  No engine, no
///     worker pool.  Runs entirely in a dedicated isolate.
///   - **engineOnly** — Greedy best-eval move selection using Stockfish.
///   - **metaEval** — Propagated MetaEase (opponentEase) with eval guard.
///
/// The engine-backed strategies (engineOnly, metaEval) use the shared
/// [MoveAnalysisPool] singleton.  winRateOnly never touches the pool.
///
/// Strategy-specific selection and aggregation logic lives in
/// [MoveSelectionPolicy] implementations, keeping this file focused on
/// the DFS traversal and candidate building.
library;

import 'dart:isolate';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import 'db_only_generation_isolate.dart';
import 'ease_calculator.dart';
import 'generation/candidate_move.dart';
import 'generation/engine_only_policy.dart';
import 'generation/generation_config.dart';
import 'generation/meta_eval_policy.dart';
import 'generation/move_selection_policy.dart';
import 'lichess_auth_service.dart';
import 'maia_factory.dart';
import 'move_analysis_pool.dart';
import 'probability_service.dart';

export 'generation/candidate_move.dart';
export 'generation/generation_config.dart';

// ── Probability threshold constants ──────────────────────────────────────
//
// All move-filtering thresholds are defined here so they can be tuned in
// one place.  Values are in the same unit as [ExplorerMove.playRate]
// (percentage, 0–100) unless noted otherwise.

/// Minimum play rate for a DB move to be merged into our engine candidate
/// set.  Higher than [_kMinOurMovePlayRate] because engine candidates are
/// already high-quality; DB suggestions are supplementary.
const double _kMinLikelyPlayRate = 2.0;

/// Minimum play rate for a DB move to be considered as our response in
/// leaf-extension scenarios.
const double _kMinOurMovePlayRate = 1.0;

/// Minimum play fraction (0–1) for an opponent reply to be branched on.
const double _kMinOpponentPlayFraction = 0.01;

// ── Generation service ──────────────────────────────────────────────────

class RepertoireGenerationService {
  final MoveAnalysisPool _pool = MoveAnalysisPool();
  final ProbabilityService _probabilityService = ProbabilityService();

  static const int _maxCacheEntries = 100000;
  final Map<String, int> _evalWhiteCache = {};
  final Map<String, ExplorerResponse?> _dbCache = {};
  final Map<String, double> _metaEaseCache = {};

  int _nodesVisited = 0;
  int _linesGenerated = 0;
  int _engineCalls = 0;
  int _engineCacheHits = 0;
  int _dbCalls = 0;
  int _dbCacheHits = 0;

  void _log(String msg) {
    if (kDebugMode) print('[Gen] $msg');
  }

  MoveSelectionPolicy _createPolicy(GenerationStrategy strategy) {
    switch (strategy) {
      case GenerationStrategy.engineOnly:
        return const EngineOnlyPolicy();
      case GenerationStrategy.metaEval:
        return const MetaEvalPolicy();
      case GenerationStrategy.winRateOnly:
        throw StateError('winRateOnly uses isolate-based generation');
    }
  }

  Future<void> generate({
    required RepertoireGenerationConfig config,
    required GenerationStrategy strategy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
  }) async {
    _nodesVisited = 0;
    _linesGenerated = 0;
    _engineCalls = 0;
    _engineCacheHits = 0;
    _dbCalls = 0;
    _dbCacheHits = 0;
    _evalWhiteCache.clear();
    _dbCache.clear();
    _metaEaseCache.clear();

    _log('═══ Generation START ═══');
    _log('Strategy: ${strategy.name}');
    _log('Start FEN: ${config.startFen}');
    _log('White repertoire: ${config.isWhiteRepertoire}');
    _log('Max depth: ${config.maxDepthPly} ply');
    _log('Cum prob cutoff: ${config.cumulativeProbabilityCutoff}');

    final sw = Stopwatch()..start();

    if (strategy == GenerationStrategy.winRateOnly) {
      await _runDbOnlyInIsolate(config, isCancelled, onLine, onProgress, sw);
      return;
    }

    // ── Engine-backed strategies ──
    final policy = _createPolicy(strategy);

    _log('Engine depth: ${config.engineDepth}');
    _log('Opponent mass target: ${config.opponentMassTarget}');
    _log('Eval window: [${config.minEvalCpForUs}, ${config.maxEvalCpForUs}] cp');

    await _pool.beginGeneration();
    _log('Pool ready: ${_pool.workerCount} workers');

    onProgress(GenerationProgress(
      nodesVisited: 0,
      linesGenerated: 0,
      currentDepth: 0,
      message: 'Using ${_pool.workerCount} engine workers (shared pool)',
    ));

    try {
      await _dfsNode(
        config: config,
        policy: policy,
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
      _pool.endGeneration();
      sw.stop();
      _log('═══ Generation END ═══');
      _log('Time: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      _log('Nodes: $_nodesVisited, Lines: $_linesGenerated');
      _log('Engine calls: $_engineCalls (cache hits: $_engineCacheHits)');
      _log('DB calls: $_dbCalls (cache hits: $_dbCacheHits)');
      _log('Cache sizes: eval=${_evalWhiteCache.length}, '
          'db=${_dbCache.length}, meta=${_metaEaseCache.length}');
    }
  }

  // ── DB-only isolate dispatch ───────────────────────────────────────────

  Future<void> _runDbOnlyInIsolate(
    RepertoireGenerationConfig config,
    bool Function() isCancelled,
    Future<void> Function(GeneratedLine line) onLine,
    void Function(GenerationProgress progress) onProgress,
    Stopwatch sw,
  ) async {
    _pool.suspendWorkers();
    _log('DB-only strategy — suspended engine workers to free RAM');
    _log('Spawning dedicated isolate for DB queries…');
    onProgress(const GenerationProgress(
      nodesVisited: 0,
      linesGenerated: 0,
      currentDepth: 0,
      message: 'DB-only mode — isolate starting…',
    ));

    final authToken = await LichessAuthService().getValidToken();
    final resultPort = ReceivePort();
    SendPort? cancelPort;

    await Isolate.spawn(
      dbOnlyIsolateEntry,
      DbOnlyIsolateRequest(
        resultPort: resultPort.sendPort,
        startFen: config.startFen,
        isWhiteRepertoire: config.isWhiteRepertoire,
        cumulativeProbabilityCutoff: config.cumulativeProbabilityCutoff,
        maxDepthPly: config.maxDepthPly,
        authToken: authToken,
      ),
      debugName: 'db-only-gen',
    );

    await for (final msg in resultPort) {
      if (isCancelled() && cancelPort != null) {
        cancelPort.send(true);
      }
      if (msg is DbOnlyCancelPort) {
        cancelPort = msg.cancelPort;
        if (isCancelled()) cancelPort.send(true);
      } else if (msg is DbOnlyProgress) {
        _nodesVisited = msg.nodesVisited;
        _linesGenerated = msg.linesGenerated;
        onProgress(GenerationProgress(
          nodesVisited: msg.nodesVisited,
          linesGenerated: msg.linesGenerated,
          currentDepth: msg.currentDepth,
          message: msg.message,
        ));
      } else if (msg is DbOnlyLine) {
        await onLine(GeneratedLine(
          movesSan: msg.movesSan,
          cumulativeProbability: msg.cumulativeProbability,
          finalEvalWhiteCp: 0,
          metaEase: 0.0,
        ));
      } else if (msg is DbOnlyLog) {
        _log(msg.message);
      } else if (msg is DbOnlyDone) {
        _nodesVisited = msg.nodesVisited;
        _linesGenerated = msg.linesGenerated;
        _dbCalls = msg.dbCalls;
        _dbCacheHits = msg.dbCacheHits;
        sw.stop();
        _log('═══ Generation END ═══');
        _log('Time: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
        _log('Nodes: $_nodesVisited, Lines: $_linesGenerated');
        _log('DB calls: $_dbCalls (cache hits: $_dbCacheHits)');
        resultPort.close();
        break;
      }
    }
  }

  // ── Cache management ──────────────────────────────────────────────────

  void _evictCachesIfNeeded() {
    _evictOldest(_evalWhiteCache);
    _evictOldest(_dbCache);
    _evictOldest(_metaEaseCache);
  }

  static void _evictOldest(Map<dynamic, dynamic> cache) {
    if (cache.length <= _maxCacheEntries) return;
    final excess = cache.length - (_maxCacheEntries * 9 ~/ 10);
    final keys = cache.keys.take(excess).toList();
    for (final k in keys) {
      cache.remove(k);
    }
  }

  // ── Engine-backed DFS (engineOnly, metaEval) ──────────────────────────

  Future<double> _dfsNode({
    required RepertoireGenerationConfig config,
    required MoveSelectionPolicy policy,
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

    if (!emitLines && _metaEaseCache.containsKey(fen)) {
      _log('  ${"│ " * depth}MetaEase cache hit → '
          '${_metaEaseCache[fen]!.toStringAsFixed(3)}');
      return _metaEaseCache[fen]!;
    }

    _nodesVisited++;
    if (_nodesVisited % 500 == 0) _evictCachesIfNeeded();

    final indent = "│ " * depth;
    final pass = emitLines ? 'EMIT' : 'EXPLORE';
    final lastMove = lineSan.isNotEmpty ? lineSan.last : '(root)';
    _log('$indent┌ Node #$_nodesVisited  d=$depth  $pass  '
        'move=$lastMove  '
        'cumProb=${(cumulativeProb * 100).toStringAsFixed(2)}%');

    onProgress(GenerationProgress(
      nodesVisited: _nodesVisited,
      linesGenerated: _linesGenerated,
      currentDepth: depth,
      message: '$pass d=$depth $lastMove  '
          '(${_nodesVisited}n ${_linesGenerated}L  '
          'eng=$_engineCalls db=$_dbCalls)',
    ));

    final nodeSw = Stopwatch()..start();

    final evalWhiteCp = await _evaluateWhiteCp(fen, config.engineDepth);
    final evalForUs = config.toOurPerspective(evalWhiteCp);
    _log('$indent│ eval=${evalForUs}cp (white=${evalWhiteCp}cp) '
        '[${nodeSw.elapsedMilliseconds}ms]');

    final isWhiteToMove =
        fen.split(' ').length >= 2 && fen.split(' ')[1] == 'w';
    final isOurMove = isWhiteToMove == config.isWhiteRepertoire;

    final reachedStop = depth >= config.maxDepthPly ||
        cumulativeProb < config.cumulativeProbabilityCutoff ||
        evalForUs >= config.maxEvalCpForUs ||
        evalForUs <= config.minEvalCpForUs;

    final pos = Chess.fromSetup(Setup.parseFen(fen));
    if (reachedStop || pos.legalMoves.isEmpty) {
      return _handleLeaf(
        config: config,
        policy: policy,
        fen: fen,
        pos: pos,
        depth: depth,
        cumulativeProb: cumulativeProb,
        lineSan: lineSan,
        emitLines: emitLines,
        evalWhiteCp: evalWhiteCp,
        evalForUs: evalForUs,
        isOurMove: isOurMove,
        indent: indent,
        nodeSw: nodeSw,
        onLine: onLine,
      );
    }

    double result;
    if (isOurMove) {
      _log('$indent│ OUR MOVE (selecting best candidate)');
      result = await _handleOurMove(
        config: config,
        policy: policy,
        isCancelled: isCancelled,
        onLine: onLine,
        onProgress: onProgress,
        fen: fen,
        depth: depth,
        cumulativeProb: cumulativeProb,
        lineSan: lineSan,
        emitLines: emitLines,
      );
    } else {
      _log('$indent│ OPPONENT MOVE (branching on likely replies)');
      result = await _handleOpponentMove(
        config: config,
        policy: policy,
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

    _log('$indent└ Done d=$depth result=${result.toStringAsFixed(3)} '
        '[${nodeSw.elapsedMilliseconds}ms total]');
    return result;
  }

  // ── Leaf handling ─────────────────────────────────────────────────────

  Future<double> _handleLeaf({
    required RepertoireGenerationConfig config,
    required MoveSelectionPolicy policy,
    required String fen,
    required Chess pos,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
    required bool emitLines,
    required int evalWhiteCp,
    required int evalForUs,
    required bool isOurMove,
    required String indent,
    required Stopwatch nodeSw,
    required Future<void> Function(GeneratedLine line) onLine,
  }) async {
    String reason = 'legal moves empty';
    if (depth >= config.maxDepthPly) reason = 'max depth';
    if (cumulativeProb < config.cumulativeProbabilityCutoff) {
      reason = 'cum prob too low';
    }
    if (evalForUs >= config.maxEvalCpForUs) reason = 'eval too high';
    if (evalForUs <= config.minEvalCpForUs) reason = 'eval too low';

    double metaEase = 0.5;
    if (policy.requiresEase) {
      final nodeEase = await EaseCalculator.compute(
        fen: fen,
        evalDepth: config.easeDepth,
        maiaElo: config.maiaElo,
        evaluateBatch: _pool.evaluateMany,
        dbData: await _getDbData(fen),
      );
      metaEase = 1.0 - (nodeEase ?? 0.5);
    }

    if (emitLines && lineSan.isNotEmpty) {
      var finalLine = lineSan;
      if (isOurMove && pos.legalMoves.isNotEmpty) {
        final response = await _findOurBestResponse(fen, config);
        if (response != null) finalLine = [...lineSan, response];
      }
      final endsWithOurMove =
          !isOurMove || finalLine.length > lineSan.length;
      if (endsWithOurMove) {
        _linesGenerated++;
        await onLine(GeneratedLine(
          movesSan: finalLine,
          cumulativeProbability: cumulativeProb,
          finalEvalWhiteCp: evalWhiteCp,
          metaEase: metaEase,
        ));
        _log('$indent│ ★ EMITTED line #$_linesGenerated: '
            '${finalLine.join(" ")}');
      } else {
        _log('$indent│ ✗ Skipped emission (ends on opponent move)');
      }
    }

    _log('$indent└ LEAF ($reason) metaEase=${metaEase.toStringAsFixed(3)} '
        '[${nodeSw.elapsedMilliseconds}ms]');
    _metaEaseCache[fen] = metaEase;
    return metaEase;
  }

  // ── Our move — delegates selection to MoveSelectionPolicy ─────────────

  Future<double> _handleOurMove({
    required RepertoireGenerationConfig config,
    required MoveSelectionPolicy policy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
    required String fen,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
    required bool emitLines,
  }) async {
    final indent = "│ " * depth;
    final sw = Stopwatch()..start();

    final candidates = await _buildOurCandidates(fen: fen, config: config);
    if (candidates.isEmpty) {
      _log('$indent│ No candidates found');
      return 0.0;
    }

    _log('$indent│ ${candidates.length} candidates built '
        '[${sw.elapsedMilliseconds}ms]:');
    for (final c in candidates) {
      _log('$indent│   ${c.san}  eval=${c.evalWhiteCp}cp  '
          'winRate=${(c.winRate * 100).toStringAsFixed(1)}%');
    }

    // ── Eval guard filter ──
    final bestEvalForUs = candidates
        .map((c) => config.toOurPerspective(c.evalWhiteCp))
        .reduce(math.max);

    final valid = candidates.where((c) {
      final childEval = config.toOurPerspective(c.evalWhiteCp);
      return childEval >= bestEvalForUs - config.maxEvalLossCp &&
          childEval >= config.minEvalCpForUs;
    }).toList();

    final candidatePool = valid.isNotEmpty ? valid : candidates;
    _log('$indent│ ${candidatePool.length} candidates after eval filter '
        '(best=${bestEvalForUs}cp, window=${config.maxEvalLossCp}cp)');

    // ── Delegate to the policy ──
    final selected = await policy.selectOurMove(
      candidates: candidatePool,
      config: config,
      isCancelled: isCancelled,
      exploreSubtree: (c) => _dfsNode(
        config: config,
        policy: policy,
        isCancelled: isCancelled,
        onLine: onLine,
        onProgress: onProgress,
        fen: c.childFen,
        depth: depth + 1,
        cumulativeProb: cumulativeProb,
        lineSan: [...lineSan, c.san],
        emitLines: false,
      ),
    );

    if (selected == null) return 0.0;
    _log('$indent│ Selected: ${selected.san} ${selected.evalWhiteCp}cp');

    final result = await _dfsNode(
      config: config,
      policy: policy,
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

  // ── Opponent move (chance node) ───────────────────────────────────────

  Future<double> _handleOpponentMove({
    required RepertoireGenerationConfig config,
    required MoveSelectionPolicy policy,
    required bool Function() isCancelled,
    required Future<void> Function(GeneratedLine line) onLine,
    required void Function(GenerationProgress progress) onProgress,
    required String fen,
    required int depth,
    required double cumulativeProb,
    required List<String> lineSan,
    required bool emitLines,
  }) async {
    final indent = "│ " * depth;

    final oppMoves = await _getOpponentMoves(
      fen: fen,
      maiaElo: config.maiaElo,
    );
    if (oppMoves.isEmpty) {
      _log('$indent│ No opponent moves found');
      return 0.0;
    }

    _log('$indent│ ${oppMoves.length} opponent moves:');
    for (final m in oppMoves) {
      _log('$indent│   ${m.uci} '
          'p=${(m.probability * 100).toStringAsFixed(1)}%');
    }

    // ── Ease (only if the policy requires it) ──
    double? localEase;
    if (policy.requiresEase) {
      localEase = await EaseCalculator.compute(
        fen: fen,
        evalDepth: config.easeDepth,
        maiaElo: config.maiaElo,
        evaluateBatch: _pool.evaluateMany,
        dbData: await _getDbData(fen),
      );
    }

    final childFens = <String>[];
    final childSans = <String>[];
    final validIndices = <int>[];
    for (int i = 0; i < oppMoves.length; i++) {
      final childFen = playUciMove(fen, oppMoves[i].uci);
      if (childFen == null) continue;
      childFens.add(childFen);
      childSans.add(uciToSan(fen, oppMoves[i].uci));
      validIndices.add(i);
    }

    double future = 0.0;
    for (int j = 0; j < childFens.length; j++) {
      if (isCancelled()) break;

      final idx = validIndices[j];
      final prob = oppMoves[idx].probability;

      _log('$indent│ Opponent reply ${j + 1}/${childFens.length}: '
          '${childSans[j]} (${(prob * 100).toStringAsFixed(1)}%)');

      final v = await _dfsNode(
        config: config,
        policy: policy,
        isCancelled: isCancelled,
        onLine: onLine,
        onProgress: onProgress,
        fen: childFens[j],
        depth: depth + 1,
        cumulativeProb: cumulativeProb * prob,
        lineSan: [...lineSan, childSans[j]],
        emitLines: emitLines,
      );
      future += prob * v;
    }

    final result = policy.computeOpponentNodeValue(
      weightedFuture: future,
      localEase: localEase,
      config: config,
    );

    _metaEaseCache[fen] = result;
    return result;
  }

  // ── Candidate building ────────────────────────────────────────────────

  Future<List<CandidateMove>> _buildOurCandidates({
    required String fen,
    required RepertoireGenerationConfig config,
  }) async {
    final isWhiteToMove = fen.split(' ')[1] == 'w';

    _log('    Building candidates: '
        'MultiPV discovery depth=${config.engineDepth}...');
    final discSw = Stopwatch()..start();
    final discovery = await _pool.discoverMoves(
      fen: fen,
      depth: config.engineDepth,
      multiPv: config.engineTopK,
      isWhiteToMove: isWhiteToMove,
    );
    _log('    Discovery done [${discSw.elapsedMilliseconds}ms]: '
        '${discovery.lines.length} lines');

    final engineUcis = discovery.lines
        .map((l) => l.moveUci)
        .where((u) => u.isNotEmpty)
        .take(config.engineTopK)
        .toList();

    final likely =
        await _getLikelyMovesForUs(fen, maiaElo: config.maiaElo);
    final merged = <String>{...engineUcis, ...likely};
    final selectedUcis = merged.take(config.maxCandidates).toList();

    _log('    Merged ${engineUcis.length} engine + ${likely.length} DB/Maia '
        '→ ${selectedUcis.length} candidates');

    final childFens = <String>[];
    final validUcis = <String>[];
    for (final uci in selectedUcis) {
      final childFen = playUciMove(fen, uci);
      if (childFen == null) continue;
      childFens.add(childFen);
      validUcis.add(uci);
    }

    _log('    Evaluating ${childFens.length} candidates at '
        'depth ${config.engineDepth}...');
    final evalSw = Stopwatch()..start();
    final evalResults =
        await _pool.evaluateMany(childFens, config.engineDepth);
    _log('    Candidate evals done [${evalSw.elapsedMilliseconds}ms]');

    final parentIsWhiteToMove = isWhiteToMove;

    final dbData = await _getDbData(fen);
    final byUci = <String, ExplorerMove>{};
    if (dbData != null) {
      for (final m in dbData.moves) {
        if (m.uci.isNotEmpty) byUci[m.uci] = m;
      }
    }

    final out = <CandidateMove>[];
    for (int i = 0; i < validUcis.length; i++) {
      final uci = validUcis[i];
      final eval = evalResults[i];
      final evalWhiteCp =
          parentIsWhiteToMove ? -eval.effectiveCp : eval.effectiveCp;

      _evalWhiteCache['${childFens[i]}|${config.engineDepth}'] =
          evalWhiteCp;

      final san = uciToSan(fen, uci);
      final dbMove = byUci[uci];
      final winRate = dbMove?.winRateFor(asWhite: config.isWhiteRepertoire)
          ?? 0.5;

      out.add(CandidateMove(
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

  Future<List<String>> _getLikelyMovesForUs(
    String fen, {
    required int maiaElo,
  }) async {
    final db = await _getDbData(fen);
    if (db != null && db.moves.isNotEmpty) {
      final sorted = db.moves.toList()
        ..sort((a, b) => b.playRate.compareTo(a.playRate));
      return sorted
          .where((m) => m.uci.isNotEmpty && m.playRate >= _kMinLikelyPlayRate)
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
        .where((e) => e.value >= _kMinLikelyPlayRate / 100.0)
        .map((e) => e.key)
        .toList();
  }

  Future<List<_ProbMove>> _getOpponentMoves({
    required String fen,
    required int maiaElo,
  }) async {
    final out = <_ProbMove>[];
    final db = await _getDbData(fen);
    if (db != null && db.moves.isNotEmpty) {
      final sorted = db.moves.toList()
        ..sort((a, b) => b.playRate.compareTo(a.playRate));
      for (final m in sorted) {
        if (m.uci.isEmpty) continue;
        final p = m.playFraction;
        if (p < _kMinOpponentPlayFraction) continue;
        out.add(_ProbMove(uci: m.uci, probability: p));
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
    for (final e in sorted) {
      if (e.value < _kMinOpponentPlayFraction) continue;
      out.add(_ProbMove(uci: e.key, probability: e.value));
    }
    return out;
  }

  // ── DB + eval helpers ─────────────────────────────────────────────────

  Future<ExplorerResponse?> _getDbData(String fen) async {
    if (_dbCache.containsKey(fen)) {
      _dbCacheHits++;
      return _dbCache[fen];
    }
    _dbCalls++;
    final sw = Stopwatch()..start();
    final data = await _probabilityService.getProbabilitiesForFen(fen);
    _log('  DB#$_dbCalls ${sw.elapsedMilliseconds}ms  '
        '${data?.moves.length ?? 0} moves  '
        '${data?.totalGames ?? 0} games');
    _dbCache[fen] = data;
    return data;
  }

  Future<int> _evaluateWhiteCp(String fen, int depth) async {
    final key = '$fen|$depth';
    final cached = _evalWhiteCache[key];
    if (cached != null) {
      _engineCacheHits++;
      return cached;
    }

    _engineCalls++;
    final eval = await _pool.evaluateFen(fen, depth);
    final isWhiteToMove = fen.split(' ')[1] == 'w';
    final whiteCp = isWhiteToMove ? eval.effectiveCp : -eval.effectiveCp;
    _evalWhiteCache[key] = whiteCp;
    return whiteCp;
  }

  /// Find our best response at a leaf position using DB data.
  Future<String?> _findOurBestResponse(
    String fen,
    RepertoireGenerationConfig config,
  ) async {
    final dbData = await _getDbData(fen);
    return dbData
        ?.bestMoveForSide(
          asWhite: config.isWhiteRepertoire,
          minPlayRate: _kMinOurMovePlayRate,
        )
        ?.san;
  }
}

// ── Internal data types ─────────────────────────────────────────────────

class _ProbMove {
  final String uci;
  final double probability;

  const _ProbMove({required this.uci, required this.probability});
}
