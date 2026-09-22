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
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/analysis/discovery_result.dart';
import '../../utils/eval_constants.dart';
import 'engine_connection.dart';
import 'engine_interrupt.dart';
import 'engine_search_budget.dart';
import 'engine_serial_queue.dart';
import 'uci_info_line.dart';

/// Single-position evaluation, side-to-move perspective.
class EvalResult {
  final int? scoreCp;
  final int? scoreMate;
  final List<String> pv;
  final int depth;

  const EvalResult({
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

enum EngineWorkerState { idle, searching, stopping, dead, disposed }

/// Owns the complete UCI transaction: admission, options, go, stop and bestmove.
/// A cancelled caller returns promptly, but the serial transaction retains its
/// CPU allocation and output ownership until bestmove (or process retirement).
/// Every consumer, including the bulk pool, therefore gets safe worker reuse.
class EvalWorker {
  EvalWorker(
    this.engine, {
    required EngineSearchBudget budget,
    this.protocolTimeout = const Duration(seconds: 10),
  }) : _budget = budget {
    _sub = engine.stdout.listen(_onOutput, onError: _die, onDone: () => _die());
    unawaited(engine.done.then((_) => _die(), onError: _die));
  }

  static const _defaultHashMb = 128;

  final EngineConnection engine;
  final EngineSearchBudget _budget;
  final Duration protocolTimeout;
  late final StreamSubscription<String> _sub;
  final _queue = EngineSerialQueue();
  final _retired = Completer<void>();
  final Set<_SearchRequest<Object>> _requests = {};

  /// The request whose output the engine is currently producing. Parsing state
  /// lives on the request and is only replaced after its predecessor's
  /// bestmove, so cancellation never makes old output eligible for a new one.
  _SearchRequest<Object>? _active;
  Completer<void>? _ready;
  Timer? _stopTimer;
  bool _initialized = false;
  EngineWorkerState _state = EngineWorkerState.idle;
  EngineWorkerState get state => _state;
  bool get isDead =>
      _state == EngineWorkerState.dead || _state == EngineWorkerState.disposed;

  /// Invoked once when the process dies unexpectedly (never on [dispose]).
  void Function()? onDied;

  /// Single-position searches launched by any worker; benchmarks reset it.
  static int searchCount = 0;
  int _requestedThreads = 1;
  int _currentThreads = 1;
  int _currentHashMb = _defaultHashMb;
  int get hashMb => _currentHashMb;

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

  Future<void> init({int hashMb = _defaultHashMb, int threads = 1}) =>
      _queue.run(() async {
        _checkAlive();
        _requestedThreads = math.max(1, threads);
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
    _requestedThreads = math.max(1, threads);
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
    _DiscoveryRequest(
      fen,
      depth,
      multiPv: multiPv,
      whiteToMove: isWhiteToMove,
      searchMoves: searchMoves,
      onProgress: onProgress,
    ),
  );

  Future<EvalResult> evaluateFen(String fen, int depth) =>
      _submit(_EvalRequest(fen, depth));

  Future<T> _submit<T extends Object>(_SearchRequest<T> request) {
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

  Future<void> _execute(_SearchRequest<Object> request) async {
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
      engine.sendCommand('setoption name MultiPV value ${request.multiPv}');
      await _syncReady();
      request.cancellation.check();
      _active = request;
      _state = EngineWorkerState.searching;
      if (request is _EvalRequest) searchCount++;
      engine.sendCommand('position fen ${request.fen}');
      engine.sendCommand(request.goCommand);
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

  /// Cancel every queued caller and ask the engine to end the active search.
  /// The transaction itself still waits for bestmove (or retires on timeout).
  void stop() {
    for (final request in _requests) {
      request.cancellation.cancel();
      request.fail(EngineSearchCancelled());
    }
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
      request.complete();
      _finishActive();
    } else if (!request.cancellation.isCancelled &&
        line.startsWith('info') &&
        line.contains('score')) {
      request.absorb(UciInfoLine.parse(line));
    }
  }

  void _finishActive() {
    _stopTimer?.cancel();
    _stopTimer = null;
    final active = _active;
    _active = null;
    if (!isDead) _state = EngineWorkerState.idle;
    if (active != null && !active.finished.isCompleted) {
      active.finished.complete();
    }
  }

  void _die([Object? error]) {
    if (isDead) return;
    _state = EngineWorkerState.dead;
    _retire(error ?? EngineProcessExitedError());
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
    _retire(EngineWorkerDisposedError());
  }
}

/// One search transaction and the output it has accumulated so far.
sealed class _SearchRequest<T extends Object> {
  _SearchRequest(this.fen, this.depth, {this.searchMoves});
  final String fen;
  final int depth;
  final List<String>? searchMoves;
  final cancellation = EngineSearchCancellation();

  /// The caller's result: a value on bestmove, an error on cancel/retire.
  final result = Completer<T>();

  /// The transaction's end: bestmove seen or the worker retired.
  final finished = Completer<void>();

  int get multiPv;

  String get goCommand {
    final moves = searchMoves;
    final restriction = moves == null || moves.isEmpty
        ? ''
        : ' searchmoves ${moves.join(' ')}';
    return 'go depth $depth$restriction';
  }

  /// Fold one `info … score …` line into the running result.
  void absorb(UciInfoLine info);

  T buildResult();

  void complete() {
    if (!result.isCompleted) result.complete(buildResult());
  }

  void fail(Object error) {
    if (!result.isCompleted) result.completeError(error);
  }
}

final class _EvalRequest extends _SearchRequest<EvalResult> {
  _EvalRequest(super.fen, super.depth);

  int? _scoreCp;
  int? _scoreMate;
  List<String> _pv = const [];
  int _depth = 0;

  @override
  int get multiPv => 1;

  @override
  void absorb(UciInfoLine info) {
    _depth = info.depth ?? _depth;
    if (info.scoreCp != null) {
      _scoreCp = info.scoreCp;
      _scoreMate = null;
    } else if (info.scoreMate != null) {
      _scoreMate = info.scoreMate;
      _scoreCp = null;
    }
    _pv = info.pv ?? _pv;
  }

  @override
  EvalResult buildResult() => EvalResult(
    scoreCp: _scoreCp,
    scoreMate: _scoreMate,
    pv: List.of(_pv),
    depth: _depth,
  );
}

final class _DiscoveryRequest extends _SearchRequest<DiscoveryResult> {
  _DiscoveryRequest(
    super.fen,
    super.depth, {
    required this.multiPv,
    required this.whiteToMove,
    super.searchMoves,
    this.onProgress,
  });

  @override
  final int multiPv;
  final bool whiteToMove;
  final void Function(DiscoveryResult)? onProgress;

  final Map<int, DiscoveryLine> _lines = {};
  int _depth = 0;
  int _nodes = 0;
  int _nps = 0;

  @override
  void absorb(UciInfoLine info) {
    final depth = info.depth;
    if (depth == null) return;
    final pvNumber = info.multiPv ?? 1;
    _lines[pvNumber] = DiscoveryLine(
      pvNumber: pvNumber,
      depth: depth,
      scoreCp: _whiteRelative(info.scoreCp),
      scoreMate: _whiteRelative(info.scoreMate),
      pv: info.pv ?? const [],
      nodes: info.nodes ?? 0,
      nps: info.nps ?? 0,
    );
    _depth = depth;
    if (info.nodes case final nodes?) _nodes = nodes;
    if (info.nps case final nps?) _nps = nps;
    onProgress?.call(buildResult());
  }

  int? _whiteRelative(int? score) =>
      score == null || whiteToMove ? score : -score;

  @override
  DiscoveryResult buildResult() => DiscoveryResult(
    lines: _lines.values.toList()
      ..sort((a, b) => a.pvNumber.compareTo(b.pvNumber)),
    depth: _depth,
    nodes: _nodes,
    nps: _nps,
  );
}
