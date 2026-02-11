/// Parallel move analysis using a pool of single-threaded Stockfish workers.
///
/// After MultiPV gives the top N lines, this pool evaluates remaining moves
/// in parallel: each worker picks a move, evaluates the resulting position,
/// and computes the ease of that position.
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:chess/chess.dart' as chess;
import 'package:flutter/foundation.dart';

import 'engine_connection.dart';
import 'stockfish_connection_factory.dart';
import 'maia_factory.dart';
import '../models/engine_settings.dart';
import '../utils/system_info.dart';

// ── Ease formula constants ────────────────────────────────────────────────

const double kEaseAlpha = 1 / 3;
const double kEaseBeta = 1.5;

double scoreToQ(int cp) {
  if (cp.abs() > 9000) return cp > 0 ? 1.0 : -1.0;
  final winProb = 1.0 / (1.0 + math.exp(-0.004 * cp));
  return 2.0 * winProb - 1.0;
}

// ── Public result type ────────────────────────────────────────────────────

class MoveAnalysisResult {
  final int? scoreCp; // White perspective
  final int? scoreMate; // White perspective
  final List<String> pv; // Full PV (move + continuation)
  final double? moveEase; // Ease of resulting position (null while computing)
  final int depth;

  MoveAnalysisResult({
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.moveEase,
    this.depth = 0,
  });

  int get effectiveCp {
    if (scoreMate != null) {
      return scoreMate! > 0
          ? 10000 - scoreMate!.abs()
          : -(10000 - scoreMate!.abs());
    }
    return scoreCp ?? 0;
  }

  bool get hasEval => scoreCp != null || scoreMate != null;
}

// ── Structured pool status ────────────────────────────────────────────────

class PoolStatus {
  final String phase; // 'idle', 'initializing', 'analyzing', 'complete'
  final List<String> evaluatingUcis; // UCIs currently being worked on
  final int totalMoves;
  final int completedMoves;
  final int activeWorkers;
  final int hashPerWorkerMb;

  const PoolStatus({
    this.phase = 'idle',
    this.evaluatingUcis = const [],
    this.totalMoves = 0,
    this.completedMoves = 0,
    this.activeWorkers = 0,
    this.hashPerWorkerMb = 0,
  });

  bool get isIdle => phase == 'idle';
  bool get isAnalyzing => phase == 'analyzing';
  bool get isComplete => phase == 'complete';
}

// ── Internal: raw eval result (side-to-move perspective) ──────────────────

class _EvalResult {
  final int? scoreCp;
  final int? scoreMate;
  final List<String> pv;
  final int depth;

  _EvalResult({
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    required this.depth,
  });

  int get effectiveCp {
    if (scoreMate != null) {
      return scoreMate! > 0
          ? 10000 - scoreMate!.abs()
          : -(10000 - scoreMate!.abs());
    }
    return scoreCp ?? 0;
  }
}

// ── Internal: single Stockfish worker ─────────────────────────────────────

class _EvalWorker {
  final EngineConnection engine;
  late final StreamSubscription _sub;

  Completer<_EvalResult>? _evalCompleter;
  Completer<void>? _readyCompleter;
  int? _scoreCp;
  int? _scoreMate;
  List<String> _pv = [];
  int _depth = 0;

  _EvalWorker(this.engine) {
    _sub = engine.stdout.listen(_onOutput);
  }

  Future<void> init({int hashMb = 16}) async {
    // The connection's waitForReady handles UCI handshake
    await engine.waitForReady();

    // Configure for single-thread worker with minimal hash.
    // The pool updates hash dynamically via updateHash() once it knows
    // how many workers were successfully created and how much RAM is free.
    engine.sendCommand('setoption name Threads value 1');
    engine.sendCommand('setoption name Hash value $hashMb');
    _readyCompleter = Completer<void>();
    engine.sendCommand('isready');
    await _readyCompleter!.future;
  }

  /// Resize the Stockfish hash table (in MB).
  /// Safe to call between evaluations; Stockfish re-allocates on the fly.
  void updateHash(int hashMb) {
    engine.sendCommand('setoption name Hash value $hashMb');
  }

  /// Evaluate a position at the given depth. Returns raw side-to-move scores.
  Future<_EvalResult> evaluateFen(String fen, int depth) async {
    if (_evalCompleter != null && !_evalCompleter!.isCompleted) {
      _evalCompleter!.completeError('Cancelled');
    }

    _evalCompleter = Completer<_EvalResult>();
    _scoreCp = null;
    _scoreMate = null;
    _pv = [];
    _depth = 0;

    engine.sendCommand('stop');
    engine.sendCommand('position fen $fen');
    engine.sendCommand('go depth $depth');

    return _evalCompleter!.future;
  }

  /// Cancel any in-progress evaluation.
  void stop() {
    engine.sendCommand('stop');
    if (_evalCompleter != null && !_evalCompleter!.isCompleted) {
      _evalCompleter!.completeError('Cancelled');
      _evalCompleter = null;
    }
  }

  void _onOutput(String line) {
    line = line.trim();
    if (line.isEmpty) return;

    if (line == 'readyok') {
      _readyCompleter?.complete();
      _readyCompleter = null;
      return;
    }

    // Ignore non-eval output
    if (_evalCompleter == null || _evalCompleter!.isCompleted) return;

    if (line.startsWith('info') && line.contains('score')) {
      _parseInfo(line);
    } else if (line.startsWith('bestmove')) {
      _evalCompleter?.complete(_EvalResult(
        scoreCp: _scoreCp,
        scoreMate: _scoreMate,
        pv: List.from(_pv),
        depth: _depth,
      ));
      _evalCompleter = null;
    }
  }

  void _parseInfo(String line) {
    final parts = line.split(' ');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i] == 'depth' && i + 1 < parts.length) {
        _depth = int.tryParse(parts[i + 1]) ?? _depth;
      } else if (parts[i] == 'score' && i + 2 < parts.length) {
        final type = parts[i + 1];
        final val = int.tryParse(parts[i + 2]);
        if (type == 'cp' && val != null) {
          _scoreCp = val;
          _scoreMate = null;
        } else if (type == 'mate' && val != null) {
          _scoreMate = val;
          _scoreCp = null;
        }
      } else if (parts[i] == 'pv' && i + 1 < parts.length) {
        _pv = parts.sublist(i + 1);
        break;
      }
    }
  }

  void dispose() {
    stop();
    _sub.cancel();
    try {
      engine.sendCommand('quit');
    } catch (_) {}
    engine.dispose();
  }
}

// ── Worker Pool ──────────────────────────────────────────────────────────

class MoveAnalysisPool {
  static final MoveAnalysisPool _instance = MoveAnalysisPool._();
  factory MoveAnalysisPool() => _instance;
  MoveAnalysisPool._();

  final List<_EvalWorker> _workers = [];
  int _activeWorkerCount = 0;

  // Generation counter to invalidate stale work
  int _generation = 0;

  // Shared queue index (safe in Dart's single-threaded model)
  int _nextMoveIndex = 0;

  // Track which move each worker is currently evaluating (workerIndex → uci)
  final Map<int, String> _workerCurrentMoves = {};

  // Results
  final ValueNotifier<Map<String, MoveAnalysisResult>> results =
      ValueNotifier({});

  /// Structured pool status with evaluating moves, worker count, RAM, etc.
  final ValueNotifier<PoolStatus> poolStatus =
      ValueNotifier(const PoolStatus());

  // ── Worker lifecycle helpers ───────────────────────────────────────────

  /// Dispose workers from the end until only [count] remain.
  void _trimWorkersTo(int count) {
    while (_workers.length > count) {
      _workers.removeLast().dispose();
    }
    _activeWorkerCount = _workers.length;
  }

  void _disposeAllWorkers() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    _activeWorkerCount = 0;
  }

  // ── Dynamic resource budgeting ──────────────────────────────────────

  /// Per-process non-hash overhead (Stockfish internal structures, stack, etc.)
  static const int _processOverheadMb = 40;

  /// Minimum useful Stockfish hash (MB).
  static const int _minHashMb = 16;

  /// Cores reserved for the system, Flutter UI, and main MultiPV engine.
  static const int _reservedCores = 2;

  /// Tracks the most recently applied hash for status display.
  int _lastHashPerWorkerMb = 0;

  /// Compute the dynamic worker budget from a live [SystemLoad] snapshot.
  ///
  /// 1. **CPU** — `freeCores − reservedCores`, capped at [maxWorkers].
  /// 2. **RAM** — `headroom / (minHash + processOverhead)`, so we never
  ///    spawn a worker that can't even hold a minimal hash table.
  ///
  /// The lower of the two wins. Always returns at least 1.
  int _workerBudget(SystemLoad load, double maxLoadPercent, int maxWorkers) {
    // CPU budget: free cores minus the reserved set
    final cpuBudget = (load.freeCores - _reservedCores).floor().clamp(1, maxWorkers);

    // RAM budget: how many instances (worker + main engine) can fit at
    // minimum hash + overhead? Subtract 1 for the main MultiPV engine.
    final headroom = load.headroomMb(maxLoadPercent / 100.0);
    final costPerInstance = _minHashMb + _processOverheadMb;
    final ramInstances = headroom ~/ costPerInstance;
    final ramBudget = (ramInstances - 1).clamp(1, maxWorkers); // −1 for main engine

    final budget = cpuBudget < ramBudget ? cpuBudget : ramBudget;
    return budget.clamp(1, maxWorkers);
  }

  /// Compute hash per worker from actual available RAM headroom.
  ///
  ///   available = maxLoad% × totalRam − usedRam
  ///   hashPerWorker = (available − instances × overhead) / instances
  ///
  /// Clamped to [_minHashMb .. settings.hashPerWorker].
  int _computeDynamicHash(double maxLoadPercent) {
    final settings = EngineSettings();
    final load = getSystemLoad();
    if (load == null) return settings.hashPerWorker; // can't measure, static

    final totalInstances = _workers.length + 1; // +1 for main MultiPV engine
    final headroom = load.headroomMb(maxLoadPercent / 100.0);
    final forHash = headroom - totalInstances * _processOverheadMb;
    if (forHash <= 0) return _minHashMb;

    final perInstance = forHash ~/ totalInstances;
    return perInstance.clamp(_minHashMb, settings.hashPerWorker);
  }

  /// Set hash on all live workers and log the allocation.
  void _applyDynamicHash(double maxLoadPercent) {
    final hashMb = _computeDynamicHash(maxLoadPercent);
    for (final w in _workers) {
      w.updateHash(hashMb);
    }
    _lastHashPerWorkerMb = hashMb;
    if (kDebugMode) {
      final load = getSystemLoad();
      final free = load?.freeRamMb ?? -1;
      print('[Pool] ${_workers.length} worker(s) × ${hashMb}MB hash '
          '(${free}MB free RAM)');
    }
  }

  // ── Worker creation ──────────────────────────────────────────────────

  /// Create workers dynamically based on live CPU and RAM headroom.
  ///
  /// **Algorithm** (runs before each analysis):
  ///
  /// 1. Read live CPU → compute free cores → subtract reserved →
  ///    that's our CPU-limited worker budget.
  /// 2. Read live RAM → headroom at maxLoad% → divide by (minHash +
  ///    overhead) → that's our RAM-limited budget.
  /// 3. Take the lower, cap at [maxWorkers] (user's setting).
  /// 4. Spawn workers one at a time; before each spawn re-check both
  ///    budgets — they may have shrunk because the workers we just
  ///    created already consumed resources.
  /// 5. After all spawns, compute dynamic hash from the actual free
  ///    RAM and apply to every worker.
  Future<void> _ensureWorkers({
    required double maxLoadPercent,
    required int maxWorkers,
    required int generation,
  }) async {
    if (!StockfishConnectionFactory.isAvailable) {
      _disposeAllWorkers();
      poolStatus.value = const PoolStatus(phase: 'idle');
      return;
    }

    // ── Initial budget ─────────────────────────────────────────────────
    final load = getSystemLoad();
    int targetWorkers;
    if (load != null) {
      targetWorkers = _workerBudget(load, maxLoadPercent, maxWorkers);
      if (kDebugMode) {
        print('[Pool] Budget: ${load.freeCores.toStringAsFixed(1)} free cores, '
            '${load.freeRamMb}MB free RAM → $targetWorkers worker(s) '
            '(cap $maxWorkers)');
      }
    } else {
      targetWorkers = maxWorkers; // can't measure, use setting as-is
    }

    // ── Scale down if we have too many ─────────────────────────────────
    if (_workers.length > targetWorkers) {
      _trimWorkersTo(targetWorkers);
    }

    // ── If we already have the right count, just refresh hash ──────────
    if (_workers.length == targetWorkers) {
      _activeWorkerCount = _workers.length;
      _applyDynamicHash(maxLoadPercent);
      return;
    }

    // ── Need more workers — create incrementally ───────────────────────
    // The first worker is always created so analysis can proceed even
    // when load is high. Each subsequent spawn re-checks both budgets.
    for (int i = _workers.length; i < targetWorkers; i++) {
      if (_generation != generation) return; // cancelled

      if (_workers.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (_generation != generation) return;

        // Re-check budgets — new workers consumed CPU and RAM
        final snap = getSystemLoad();
        if (snap != null) {
          final liveBudget = _workerBudget(snap, maxLoadPercent, maxWorkers);
          if (_workers.length >= liveBudget) {
            if (kDebugMode) {
              print('[Pool] Re-check: ${snap.freeCores.toStringAsFixed(1)} free cores, '
                  '${snap.freeRamMb}MB free RAM → '
                  'capping at ${_workers.length} worker(s)');
            }
            break;
          }
        }
      }

      try {
        final engine = await StockfishConnectionFactory.create();
        if (engine == null) continue;
        final worker = _EvalWorker(engine);
        await worker.init(); // starts with minimum hash (16 MB)
        _workers.add(worker);
      } catch (e) {
        break; // failed to spawn — stop trying
      }
    }

    _activeWorkerCount = _workers.length;

    // ── Apply dynamic hash based on actual free RAM ────────────────────
    _applyDynamicHash(maxLoadPercent);
  }

  // ── Analysis entry point ─────────────────────────────────────────────

  /// Analyze moves in parallel. For each move: Stockfish eval then ease.
  /// Results stream into [results] as each completes.
  ///
  /// Worker count and hash are **fully dynamic**:
  ///
  /// - **CPU first**: free cores → how many single-threaded workers fit.
  /// - **RAM second**: headroom at the load ceiling → hash per worker.
  /// - Both are re-checked before every spawn.
  /// - During analysis, workers beyond #0 re-check CPU between moves
  ///   and yield early if cores are saturated.
  ///
  /// The [numWorkers] parameter is a **maximum cap** (from user settings),
  /// not a target — the pool will use fewer if the system can't sustain it.
  Future<void> analyzeMovesParallel({
    required String baseFen,
    required List<String> movesToAnalyze,
    int evalDepth = 15,
    int? easeDepth,
    int numWorkers = 3,
  }) async {
    if (movesToAnalyze.isEmpty) return;

    // Cancel previous work
    cancel();

    _generation++;
    final myGen = _generation;

    final settings = EngineSettings();
    final maxLoadPercent = settings.maxSystemLoad.toDouble();

    poolStatus.value = PoolStatus(
      phase: 'initializing',
      totalMoves: movesToAnalyze.length,
      activeWorkers: numWorkers,
      hashPerWorkerMb: settings.hashPerWorker,
    );

    await _ensureWorkers(
      maxLoadPercent: maxLoadPercent,
      maxWorkers: numWorkers,
      generation: myGen,
    );
    if (_workers.isEmpty || _generation != myGen) return;

    _nextMoveIndex = 0;
    _workerCurrentMoves.clear();
    results.value = {};
    _emitPoolStatus(movesToAnalyze);

    final effectiveEaseDepth = easeDepth ?? evalDepth;

    // Launch every created worker — creation already dynamically
    // determined count from live CPU and sized hash from live RAM.
    final futures = <Future<void>>[];
    for (int i = 0; i < _workers.length; i++) {
      futures.add(
        _workerLoop(
          _workers[i], i, baseFen, movesToAnalyze,
          evalDepth, effectiveEaseDepth, myGen, maxLoadPercent,
        ),
      );
    }

    await Future.wait(futures);

    if (_generation == myGen) {
      // Shrink idle workers to minimum hash so the OS can reclaim RAM
      // between analysis runs. _ensureWorkers will grow them back when
      // the next analysis starts.
      for (final w in _workers) {
        w.updateHash(1); // 1 MB — Stockfish floor
      }
      _lastHashPerWorkerMb = 1;

      _workerCurrentMoves.clear();
      poolStatus.value = PoolStatus(
        phase: 'complete',
        totalMoves: movesToAnalyze.length,
        completedMoves: results.value.length,
        activeWorkers: _workers.length,
        hashPerWorkerMb: _lastHashPerWorkerMb,
      );
    }
  }

  /// Cancel the current analysis.
  void cancel() {
    _generation++;
    _workerCurrentMoves.clear();
    for (final w in _workers) {
      w.stop();
    }
    poolStatus.value = const PoolStatus();
  }

  /// Get next move from the shared queue.
  String? _getNextMove(List<String> moves) {
    if (_nextMoveIndex >= moves.length) return null;
    return moves[_nextMoveIndex++];
  }

  /// Emit structured pool status with current evaluating moves & progress.
  void _emitPoolStatus(List<String> allMoves) {
    poolStatus.value = PoolStatus(
      phase: 'analyzing',
      evaluatingUcis: _workerCurrentMoves.values.toList(),
      totalMoves: allMoves.length,
      completedMoves: results.value.length,
      activeWorkers: _workers.length,
      hashPerWorkerMb: _lastHashPerWorkerMb,
    );
  }

  Future<void> _workerLoop(
    _EvalWorker worker,
    int workerIndex,
    String baseFen,
    List<String> allMoves,
    int evalDepth,
    int easeDepth,
    int generation,
    double maxLoad,
  ) async {
    // Determine side-to-move in the base position
    final fenParts = baseFen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';

    while (_generation == generation) {
      // Workers beyond #0 check CPU before picking up the next move.
      // If the processor is saturated, this worker exits — its remaining
      // share of the queue falls to worker 0 and any other active workers.
      // (RAM pressure is managed by hash sizing, not by killing workers.)
      if (workerIndex > 0) {
        final load = getSystemLoad();
        if (load != null && load.cpuPercent >= maxLoad) {
          if (kDebugMode) {
            print('[Pool] Worker $workerIndex yielding — '
                'CPU at ${load.cpuPercent.toStringAsFixed(0)}%');
          }
          break;
        }
      }

      final uci = _getNextMove(allMoves);
      if (uci == null) break;

      // Mark this worker as evaluating this move
      _workerCurrentMoves[workerIndex] = uci;
      _emitPoolStatus(allMoves);

      try {
        // Compute resulting FEN
        final resultingFen = _playMove(baseFen, uci);
        if (resultingFen == null) continue;

        // ── Phase 1: Stockfish eval ──────────────────────────────────
        if (kDebugMode) {
          print('[Pool] W$workerIndex eval $uci depth=$evalDepth');
        }
        final eval = await worker.evaluateFen(resultingFen, evalDepth);
        if (_generation != generation) return;

        // Convert to White perspective
        // Resulting position has the OPPONENT to move.
        // Raw scores are from opponent's (side-to-move) perspective.
        // If White just moved → opponent is Black → whiteCp = -rawCp
        // If Black just moved → opponent is White → whiteCp = rawCp
        final whiteCp = eval.scoreCp != null
            ? (isWhiteToMove ? -eval.scoreCp! : eval.scoreCp!)
            : null;
        final whiteMate = eval.scoreMate != null
            ? (isWhiteToMove ? -eval.scoreMate! : eval.scoreMate!)
            : null;

        final fullPv = [uci, ...eval.pv];

        if (kDebugMode) {
          print('[Pool] W$workerIndex eval $uci → '
              'cp=$whiteCp mate=$whiteMate depth=${eval.depth}');
        }

        // Emit eval immediately (ease fills in later)
        _emitResult(
          uci,
          MoveAnalysisResult(
            scoreCp: whiteCp,
            scoreMate: whiteMate,
            pv: fullPv,
            depth: eval.depth,
          ),
        );

        _emitPoolStatus(allMoves);

        // ── Phase 2: Ease of resulting position ──────────────────────
        if (kDebugMode) {
          print('[Pool] W$workerIndex ease $uci depth=$easeDepth');
        }
        double? ease;
        try {
          ease = await _computeMoveEase(
              worker, resultingFen, eval, easeDepth, generation);
        } catch (e) {
          if (kDebugMode) {
            print('[Pool] W$workerIndex ease $uci FAILED: $e');
          }
        }
        if (_generation != generation) return;

        if (kDebugMode) {
          print('[Pool] W$workerIndex ease $uci → '
              '${ease?.toStringAsFixed(3) ?? "null"}');
        }

        // Update with ease
        _emitResult(
          uci,
          MoveAnalysisResult(
            scoreCp: whiteCp,
            scoreMate: whiteMate,
            pv: fullPv,
            depth: eval.depth,
            moveEase: ease,
          ),
        );
      } catch (_) {
        // Likely cancelled — check generation
        if (_generation != generation) return;
      } finally {
        _workerCurrentMoves.remove(workerIndex);
        _emitPoolStatus(allMoves);
      }
    }
  }

  void _emitResult(String uci, MoveAnalysisResult result) {
    final updated = Map<String, MoveAnalysisResult>.from(results.value);
    updated[uci] = result;
    results.value = updated;
  }

  /// Compute ease of a resulting position using this worker's Stockfish + Maia.
  /// [generation] is checked between candidate evaluations for early exit.
  Future<double?> _computeMoveEase(
    _EvalWorker worker,
    String fen,
    _EvalResult rootEval,
    int depth,
    int generation,
  ) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      if (kDebugMode) print('[Pool]   ease: Maia unavailable');
      return null;
    }
    final maiaProbs = await MaiaFactory.instance!.evaluate(fen, 1900);
    if (maiaProbs.isEmpty) {
      if (kDebugMode) print('[Pool]   ease: Maia returned empty probs');
      return null;
    }

    // Root Q — the best the side-to-move can achieve
    final maxQ = scoreToQ(rootEval.effectiveCp);

    // Candidate moves (Maia top moves, cumulative > 90%)
    final sorted = maiaProbs.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final candidates = <MapEntry<String, double>>[];
    double cumulativeProb = 0.0;
    for (final entry in sorted) {
      if (entry.value < 0.01) continue;
      candidates.add(entry);
      cumulativeProb += entry.value;
      if (cumulativeProb > 0.90) break;
    }
    if (candidates.isEmpty) {
      if (kDebugMode) print('[Pool]   ease: no Maia candidates above 1%');
      return null;
    }

    if (kDebugMode) {
      print('[Pool]   ease: ${candidates.length} Maia candidates, '
          'rootCp=${rootEval.effectiveCp}, maxQ=${maxQ.toStringAsFixed(3)}');
    }

    // Evaluate each candidate
    double sumWeightedRegret = 0.0;
    final game = chess.Chess.fromFEN(fen);

    for (final entry in candidates) {
      if (_generation != generation) return null;

      final candidateUci = entry.key;
      final prob = entry.value;

      final from = candidateUci.substring(0, 2);
      final to = candidateUci.substring(2, 4);
      String? promotion;
      if (candidateUci.length > 4) promotion = candidateUci.substring(4);

      if (!game.move({'from': from, 'to': to, 'promotion': promotion})) {
        continue;
      }
      final nextFen = game.fen;
      game.undo();

      final candidateEval = await worker.evaluateFen(nextFen, depth);

      // Candidate eval is from the NEXT side-to-move (2 plies from base).
      // To get value from the current position's side-to-move: negate.
      final score = -candidateEval.effectiveCp;
      final qVal = scoreToQ(score);

      final regret = math.max(0.0, maxQ - qVal);
      sumWeightedRegret += math.pow(prob, kEaseBeta) * regret;
    }

    return 1.0 - math.pow(sumWeightedRegret / 2, kEaseAlpha);
  }

  String? _playMove(String baseFen, String uci) {
    try {
      final game = chess.Chess.fromFEN(baseFen);
      final from = uci.substring(0, 2);
      final to = uci.substring(2, 4);
      String? promotion;
      if (uci.length > 4) promotion = uci.substring(4);
      if (game.move({'from': from, 'to': to, 'promotion': promotion})) {
        return game.fen;
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    cancel();
    _disposeAllWorkers();
  }
}
