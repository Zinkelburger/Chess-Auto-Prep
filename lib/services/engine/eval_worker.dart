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
import 'package:chess_auto_prep/utils/log.dart';

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

class EvalWorker {
  final EngineConnection engine;
  late final StreamSubscription _sub;

  /// Pending `isready` handshakes, completed FIFO as each `readyok` arrives.
  /// A queue (not a single completer) so overlapping handshakes — e.g.
  /// [setThreads] from pool reconfiguration racing an [evaluateFen] — can
  /// never orphan an awaiter.
  final List<Completer<void>> _readyQueue = [];

  // ── Single eval state ──
  Completer<EvalResult>? _evalCompleter;
  int? _scoreCp;
  int? _scoreMate;
  List<String> _pv = [];
  int _depth = 0;

  // ── Discovery (MultiPV) state ──
  Completer<DiscoveryResult>? _discoveryCompleter;
  final Map<int, DiscoveryLine> _discoveryLines = {};
  bool _discoveryIsWhiteToMove = true;
  int _discoveryDepth = 0;
  int _discoveryNodes = 0;
  int _discoveryNps = 0;
  void Function(DiscoveryResult)? _discoveryOnProgress;

  EvalWorker(this.engine) {
    _sub = engine.stdout.listen(
      _onOutput,
      onError: (Object error) {
        if (kDebugMode) log.e('[EvalWorker] Engine stream error: $error');
        _evalCompleter?.completeError(error);
        _evalCompleter = null;
        _discoveryCompleter?.completeError(error);
        _discoveryCompleter = null;
        _failReadyQueue(error);
      },
    );
  }

  /// Send `isready` and wait for the matching `readyok`.
  Future<void> _syncReady() {
    final c = Completer<void>();
    _readyQueue.add(c);
    engine.sendCommand('isready');
    return c.future;
  }

  void _failReadyQueue(Object error) {
    final pending = List.of(_readyQueue);
    _readyQueue.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  Future<void> init({int hashMb = 128, int threads = 1}) async {
    await engine.waitForReady();
    await _applyThreads(threads);
    engine.sendCommand('setoption name Hash value $hashMb');
    await _syncReady();
  }

  int _currentThreads = 1;

  /// Dynamically set Stockfish UCI Threads (skips if already at desired count).
  Future<void> setThreads(int threads) async {
    if (threads < 1) threads = 1;
    if (_currentThreads == threads) return;
    await _applyThreads(threads);
    await _syncReady();
  }

  Future<void> _applyThreads(int threads) async {
    engine.sendCommand('setoption name Threads value $threads');
    _currentThreads = threads;
  }

  /// Run MultiPV analysis on a position. Returns when bestmove arrives.
  /// Calls [onProgress] on each info update for progressive UI.
  Future<DiscoveryResult> runDiscovery(
    String fen,
    int depth,
    int multiPv,
    bool isWhiteToMove, {
    void Function(DiscoveryResult)? onProgress,
  }) async {
    stop();

    _discoveryIsWhiteToMove = isWhiteToMove;
    _discoveryLines.clear();
    _discoveryDepth = 0;
    _discoveryNodes = 0;
    _discoveryNps = 0;
    _discoveryOnProgress = onProgress;

    engine.sendCommand('setoption name MultiPV value $multiPv');
    await _syncReady();

    // Set up completer AFTER readyok drains any stale bestmove from stop()
    _discoveryCompleter = Completer<DiscoveryResult>();

    engine.sendCommand('position fen $fen');
    engine.sendCommand('go depth $depth');

    final result = await _discoveryCompleter!.future;

    // Reset to single PV for subsequent evals
    engine.sendCommand('setoption name MultiPV value 1');
    await _syncReady();
    _discoveryOnProgress = null;

    return result;
  }

  /// Evaluate [fen] at [depth].  Returns scores in **side-to-move**
  /// perspective — negate when converting to White's viewpoint on a
  /// Black-to-move position.
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    if (_evalCompleter != null && !_evalCompleter!.isCompleted) {
      _evalCompleter!.completeError(StateError('Cancelled by new eval'));
    }
    _evalCompleter = null;

    // Drain any stale output (bestmove) from a previous stop/search.
    // readyok is guaranteed to arrive AFTER all pending output.
    engine.sendCommand('stop');
    await _syncReady();

    // Pipeline is clean — safe to set up the new eval.
    _evalCompleter = Completer<EvalResult>();
    _scoreCp = null;
    _scoreMate = null;
    _pv = [];
    _depth = 0;

    engine.sendCommand('position fen $fen');
    engine.sendCommand('go depth $depth');

    return _evalCompleter!.future;
  }

  void stop() {
    engine.sendCommand('stop');
    if (_evalCompleter != null && !_evalCompleter!.isCompleted) {
      _evalCompleter!.completeError(StateError('Eval stopped'));
      _evalCompleter = null;
    }
    if (_discoveryCompleter != null && !_discoveryCompleter!.isCompleted) {
      _discoveryCompleter!.completeError(StateError('Discovery stopped'));
      _discoveryCompleter = null;
    }
    _discoveryOnProgress = null;
  }

  void _onOutput(String line) {
    line = line.trim();
    if (line.isEmpty) return;

    if (line == 'readyok') {
      if (_readyQueue.isNotEmpty) {
        final c = _readyQueue.removeAt(0);
        if (!c.isCompleted) c.complete();
      }
      return;
    }

    // ── Discovery mode (MultiPV) ──
    if (_discoveryCompleter != null && !_discoveryCompleter!.isCompleted) {
      if (line.startsWith('info') && line.contains('score')) {
        _parseDiscoveryInfo(line);
      } else if (line.startsWith('bestmove')) {
        final lines = _discoveryLines.values.toList()
          ..sort((a, b) => a.pvNumber.compareTo(b.pvNumber));
        _discoveryCompleter!.complete(
          DiscoveryResult(
            lines: lines,
            depth: _discoveryDepth,
            nodes: _discoveryNodes,
            nps: _discoveryNps,
          ),
        );
        _discoveryCompleter = null;
      }
      return;
    }

    // ── Single eval mode ──
    if (_evalCompleter == null || _evalCompleter!.isCompleted) return;

    if (line.startsWith('info') && line.contains('score')) {
      _parseSingleInfo(line);
    } else if (line.startsWith('bestmove')) {
      _evalCompleter?.complete(
        EvalResult(
          scoreCp: _scoreCp,
          scoreMate: _scoreMate,
          pv: List.from(_pv),
          depth: _depth,
        ),
      );
      _evalCompleter = null;
    }
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

    if (depth != null && multipv != null) {
      _discoveryLines[multipv] = DiscoveryLine(
        pvNumber: multipv,
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

  void dispose() {
    stop();
    _failReadyQueue(StateError('Worker disposed'));
    _sub.cancel();
    try {
      engine.sendCommand('quit');
    } catch (_) {
      /* engine may already be closed */
    }
    engine.dispose();
  }
}
