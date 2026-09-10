/// A single persistent Stockfish worker used by [StockfishPool].
///
/// Handles UCI protocol for both MultiPV discovery and single-position
/// evaluation.  Parses engine output and converts scores.
///
/// **Score conventions:**
/// - [evaluateFen] returns scores in **side-to-move** perspective (raw from
///   the engine).  Callers must negate when the side to move is not the
///   perspective they need.
/// - [runDiscovery] returns scores **White-normalized** — the caller passes
///   [isWhiteToMove] and the worker flips Black-to-move scores internally.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine_connection.dart';
import '../../models/analysis/discovery_result.dart';
import '../../utils/eval_constants.dart';
import 'engine_search_budget.dart';
import 'engine_serial_queue.dart';

// ── Eval result (side-to-move perspective) ────────────────────────────────

class EvalResult {
  final int? scoreCp;
  final int? scoreMate;
  final List<String> pv;
  final int depth;

  EvalResult({
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    required this.depth,
  });

  /// Collapse mate / cp into a single comparable centipawn value.
  /// Positive = good for side-to-move, negative = bad.
  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: scoreCp, scoreMate: scoreMate);
}

// ── Single Stockfish worker ───────────────────────────────────────────────

enum EngineWorkerState { idle, searching, stopping, dead, disposed }

/// Owns the complete UCI transaction: admission, options, go, stop and bestmove.
/// A cancelled caller returns promptly, but the serial transaction retains its
/// CPU allocation and output ownership until bestmove (or process retirement).
/// Every consumer, including the bulk pool, therefore gets safe worker reuse.
class EvalWorker {
  EvalWorker(
    this.engine, {
    EngineSearchBudget? budget,
    this.protocolTimeout = const Duration(seconds: 10),
  }) : _budget = budget ?? EngineSearchBudget.instance {
    _sub = engine.stdout.listen(_onOutput, onError: _die, onDone: () => _die());
    unawaited(engine.done.then((_) => _die(), onError: _die));
  }

  final EngineConnection engine;
  final EngineSearchBudget _budget;
  final Duration protocolTimeout;
  late final StreamSubscription<String> _sub;
  final _queue = EngineSerialQueue();
  final _retired = Completer<void>();
  final Set<_SearchRequest> _requests = {};
  _SearchRequest? _active;
  Completer<void>? _ready;
  Timer? _stopTimer;
  bool _initialized = false;
  EngineWorkerState _state = EngineWorkerState.idle;
  EngineWorkerState get state => _state;
  bool get isDead =>
      _state == EngineWorkerState.dead || _state == EngineWorkerState.disposed;
  void Function()? onDied;
  static int searchCount = 0;
  int _requestedThreads = 1;
  int _currentThreads = 1;
  int _currentHashMb = 128;
  int get hashMb => _currentHashMb;

  // Parsing state belongs to _active and is reset only after its predecessor's
  // bestmove. Cancellation never makes old output eligible for a new request.
  int? _scoreCp;
  int? _scoreMate;
  List<String> _pv = [];
  int _depth = 0;
  final Map<int, DiscoveryLine> _discoveryLines = {};
  bool _discoveryIsWhiteToMove = true;
  int _discoveryDepth = 0;
  int _discoveryNodes = 0;
  int _discoveryNps = 0;
  void Function(DiscoveryResult)? _discoveryOnProgress;

  void _checkAlive() {
    if (isDead) throw StateError('Worker unavailable');
  }

  Future<void> _untilRetired(Future<void> operation) => Future.any([
    operation,
    _retired.future.then<void>((_) => throw StateError('Worker unavailable')),
  ]);

  Future<void> _syncReady() async {
    _checkAlive();
    final ready = _ready = Completer<void>();
    // Install the waiter before writing: transports may throw synchronously.
    final response = ready.future.timeout(protocolTimeout);
    try {
      try {
        engine.sendCommand('isready');
      } catch (error, stack) {
        ready.completeError(error, stack);
      }
      await response;
      _checkAlive();
    } catch (error) {
      _die(error);
      rethrow;
    } finally {
      if (identical(_ready, ready)) _ready = null;
    }
  }

  Future<void> init({int hashMb = 128, int threads = 1}) =>
      _queue.run(() async {
        _checkAlive();
        _requestedThreads = threads < 1 ? 1 : threads;
        if (!_initialized) {
          try {
            await _untilRetired(engine.waitForReady()).timeout(protocolTimeout);
          } catch (error) {
            _die(error);
            rethrow;
          }
        }
        _checkAlive();
        engine.sendCommand('setoption name Threads value $_requestedThreads');
        _currentThreads = _requestedThreads;
        engine.sendCommand('setoption name Hash value $hashMb');
        _currentHashMb = hashMb;
        await _syncReady();
        _initialized = true;
      });

  Future<void> setHash(int hashMb) => _queue.run(() async {
    _checkAlive();
    if (hashMb < 1 || _currentHashMb == hashMb) return;
    engine.sendCommand('setoption name Hash value $hashMb');
    await _syncReady();
    _currentHashMb = hashMb;
  });

  Future<void> setThreads(int threads) => _queue.run(() async {
    _checkAlive();
    _requestedThreads = threads < 1 ? 1 : threads;
    await _applyThreads(_requestedThreads);
  });

  Future<void> _applyThreads(int threads) async {
    if (_currentThreads == threads) return;
    engine.sendCommand('setoption name Threads value $threads');
    await _syncReady();
    _currentThreads = threads;
  }

  Future<DiscoveryResult> runDiscovery(
    String fen,
    int depth,
    int multiPv,
    bool isWhiteToMove, {
    List<String>? searchMoves,
    void Function(DiscoveryResult)? onProgress,
  }) => _submit(
    _SearchRequest(
      fen,
      depth,
      multiPv: multiPv,
      whiteToMove: isWhiteToMove,
      searchMoves: searchMoves,
      onProgress: onProgress,
    ),
  ).then((result) => result as DiscoveryResult);

  Future<EvalResult> evaluateFen(String fen, int depth) => _submit(
    _SearchRequest(fen, depth),
  ).then((result) => result as EvalResult);

  Future<Object> _submit(_SearchRequest request) {
    stop();
    if (isDead) return Future.error(StateError('Worker unavailable'));
    _requests.add(request);
    unawaited(
      _queue
          .run(() => _execute(request))
          .catchError((Object error) {
            request.fail(error);
          })
          .whenComplete(() => _requests.remove(request)),
    );
    return request.result.future;
  }

  Future<void> _execute(_SearchRequest request) async {
    EngineSearchAllocation? allocation;
    try {
      request.cancellation.check();
      _checkAlive();
      allocation = await _budget.acquire(
        _requestedThreads,
        request.cancellation,
      );
      request.cancellation.check();
      _checkAlive();
      await _applyThreads(allocation.threads);
      request.cancellation.check();
      engine.sendCommand(
        'setoption name MultiPV value ${request.multiPv ?? 1}',
      );
      await _syncReady();
      request.cancellation.check();
      _scoreCp = _scoreMate = null;
      _pv = [];
      _depth = 0;
      _discoveryLines.clear();
      _discoveryDepth = _discoveryNodes = _discoveryNps = 0;
      _discoveryIsWhiteToMove = request.whiteToMove;
      _discoveryOnProgress = request.onProgress;
      _active = request;
      _state = EngineWorkerState.searching;
      if (request.multiPv == null) searchCount++;
      engine.sendCommand('position fen ${request.fen}');
      final moves = request.searchMoves;
      engine.sendCommand(
        'go depth ${request.depth}'
        '${moves == null || moves.isEmpty ? '' : ' searchmoves ${moves.join(' ')}'}',
      );
      await request.finished.future;
    } catch (error) {
      request.fail(error);
      // A broken write while a search may have started cannot leave a reusable
      // protocol channel or release its CPU allocation without retirement.
      if (identical(_active, request)) _die(error);
    } finally {
      allocation?.release();
    }
  }

  void stop() {
    for (final request in _requests) {
      request.cancellation.cancel();
      request.fail(EngineSearchCancelled());
    }
    _discoveryOnProgress = null;
    if (_active == null || _state != EngineWorkerState.searching) return;
    _state = EngineWorkerState.stopping;
    _stopTimer = Timer(
      protocolTimeout,
      () => _die(
        TimeoutException('Stockfish did not acknowledge stop', protocolTimeout),
      ),
    );
    try {
      engine.sendCommand('stop');
    } catch (error) {
      _die(error);
    }
  }

  void _onOutput(String line) {
    if (isDead) return;
    line = line.trim();
    if (line == 'readyok') {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    final request = _active;
    if (request == null) return;
    if (line.startsWith('bestmove')) {
      if (!request.result.isCompleted) {
        request.result.complete(
          request.multiPv == null
              ? EvalResult(
                  scoreCp: _scoreCp,
                  scoreMate: _scoreMate,
                  pv: List.of(_pv),
                  depth: _depth,
                )
              : DiscoveryResult(
                  lines: _discoveryLines.values.toList()
                    ..sort((a, b) => a.pvNumber.compareTo(b.pvNumber)),
                  depth: _discoveryDepth,
                  nodes: _discoveryNodes,
                  nps: _discoveryNps,
                ),
        );
      }
      _finishActive();
    } else if (!request.cancellation.isCancelled &&
        line.startsWith('info') &&
        line.contains('score')) {
      if (request.multiPv == null) {
        _parseSingleInfo(line);
      } else {
        _parseDiscoveryInfo(line);
      }
    }
  }

  void _finishActive() {
    _stopTimer?.cancel();
    _stopTimer = null;
    final active = _active;
    _active = null;
    _discoveryOnProgress = null;
    if (!isDead) _state = EngineWorkerState.idle;
    if (active != null && !active.finished.isCompleted) {
      active.finished.complete();
    }
  }

  void _die([Object? error]) {
    if (isDead) return;
    _state = EngineWorkerState.dead;
    _retire(error ?? StateError('Stockfish process exited'));
    onDied?.call();
  }

  void _retire(Object error) {
    if (!_retired.isCompleted) _retired.complete();
    for (final request in _requests) {
      request.cancellation.cancel();
      request.fail(error);
    }
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    _finishActive();
    unawaited(_sub.cancel());
    try {
      engine.dispose();
    } catch (error) {
      // A failed transport teardown must not strand waiters or pool recovery.
      debugPrint('[EvalWorker] Transport disposal failed: $error');
    }
  }

  void dispose() {
    if (_state == EngineWorkerState.disposed) return;
    _state = EngineWorkerState.disposed;
    onDied = null;
    _retire(StateError('Worker disposed'));
  }

  void _parseDiscoveryInfo(String line) {
    final parts = line.split(' ');
    int? depth, multipv, scoreCp, scoreMate, nodes, nps;
    List<String> pv = [];

    for (int i = 0; i < parts.length; i++) {
      if (parts[i] == 'depth' && i + 1 < parts.length) {
        depth = int.tryParse(parts[i + 1]);
      } else if (parts[i] == 'multipv' && i + 1 < parts.length) {
        multipv = int.tryParse(parts[i + 1]);
      } else if (parts[i] == 'score' && i + 2 < parts.length) {
        final type = parts[i + 1];
        final val = int.tryParse(parts[i + 2]);
        if (type == 'cp' && val != null) {
          scoreCp = _discoveryIsWhiteToMove ? val : -val;
        } else if (type == 'mate' && val != null) {
          scoreMate = _discoveryIsWhiteToMove ? val : -val;
        }
      } else if (parts[i] == 'nodes' && i + 1 < parts.length) {
        nodes = int.tryParse(parts[i + 1]) ?? 0;
      } else if (parts[i] == 'nps' && i + 1 < parts.length) {
        nps = int.tryParse(parts[i + 1]) ?? 0;
      } else if (parts[i] == 'pv' && i + 1 < parts.length) {
        pv = parts.sublist(i + 1);
        break;
      }
    }

    if (depth != null) {
      _discoveryLines[multipv ?? 1] = DiscoveryLine(
        pvNumber: multipv ?? 1,
        depth: depth,
        scoreCp: scoreCp,
        scoreMate: scoreMate,
        pv: pv,
        nodes: nodes ?? 0,
        nps: nps ?? 0,
      );
      _discoveryDepth = depth;
      if (nodes != null) _discoveryNodes = nodes;
      if (nps != null) _discoveryNps = nps;

      final current = _discoveryLines.values.toList()
        ..sort((a, b) => a.pvNumber.compareTo(b.pvNumber));
      _discoveryOnProgress?.call(
        DiscoveryResult(
          lines: current,
          depth: _discoveryDepth,
          nodes: _discoveryNodes,
          nps: _discoveryNps,
        ),
      );
    }
  }

  void _parseSingleInfo(String line) {
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
}

class _SearchRequest {
  _SearchRequest(
    this.fen,
    this.depth, {
    this.multiPv,
    this.whiteToMove = true,
    this.searchMoves,
    this.onProgress,
  });
  final String fen;
  final int depth;
  final int? multiPv;
  final bool whiteToMove;
  final List<String>? searchMoves;
  final void Function(DiscoveryResult)? onProgress;
  final cancellation = EngineSearchCancellation();
  final result = Completer<Object>();
  final finished = Completer<void>();
  void fail(Object error) {
    if (!result.isCompleted) result.completeError(error);
  }
}
