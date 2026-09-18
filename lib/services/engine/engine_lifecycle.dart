/// Single source of truth for engine state across analysis and generation.
///
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../utils/safe_change_notifier.dart';
import 'board_engine.dart';
import 'engine_serial_queue.dart';
import 'stockfish_pool.dart';

enum EngineState { off, idle, analyzing, generating }

class EngineLifecycle extends ChangeNotifier with SafeChangeNotifier {
  EngineLifecycle({
    required StockfishPool pool,
    required BoardEngine board,
    required Future<bool> Function() loadEnabled,
    required Future<void> Function(bool) saveEnabled,
  }) : _pool = pool,
       _board = board,
       _loadEnabled = loadEnabled,
       _saveEnabled = saveEnabled;

  final Future<bool> Function() _loadEnabled;
  final Future<void> Function(bool) _saveEnabled;

  final StockfishPool _pool;
  final BoardEngine _board;
  final _queue = EngineSerialQueue();

  EngineState _state = EngineState.off;
  EngineState get state => _state;

  /// Whether the engine was on when generation was entered, so leaving
  /// generation restores what the user's toggle implies.
  bool _toggleStateBeforeGeneration = false;

  /// The user's persisted preference.  Only [toggleOn]/[toggleOff] (explicit
  /// user actions) change it — [suspend] shuts the engine down without
  /// touching it, so app-driven shutdowns (mode switch, app close) can't
  /// masquerade as the user disabling the engine.
  bool _userWantsEngine = false;
  bool _preferenceLoaded = false;

  /// Number of background jobs currently borrowing the shared pool (e.g. a
  /// tactics import). While positive, [suspend]/[toggleOff] cancel
  /// interactive analysis but leave the pool's workers alive — disposing
  /// them mid-import killed every search the job had in flight (the classic
  /// repro: start a tactics import, visit the Repertoire tab, leave it).
  int _poolLeases = 0;

  Future<void> _serialExec(Future<void> Function() fn) => _queue.run(() async {
    if (isDisposed) throw StateError('Engine lifecycle is disposed');
    await fn();
  });

  /// Notify now, or after the current frame when called mid-build.
  void _notifyListenersSafe() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      notifyListeners();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
    }
  }

  /// Initialize in the same queue as toggles and generation transitions.
  /// Failed reads leave the preference unknown and may be retried. A successful
  /// explicit toggle also initializes it, so a late startup call cannot undo it.
  /// Missing preferences default to enabled only after a successful read.
  Future<void> loadPersistedState() => _serialExec(() async {
    if (_preferenceLoaded) return;
    final enabled = await _loadEnabled();
    if (isDisposed) return;
    _userWantsEngine = enabled;
    _preferenceLoaded = true;
    if (_state == EngineState.generating) {
      _toggleStateBeforeGeneration = enabled;
    } else if (enabled) {
      _resumeBoard();
      _state = EngineState.idle;
      notifyListeners();
    }
  });

  Future<void> toggleOn() => _serialExec(_doToggleOn);
  Future<void> toggleOff() => _serialExec(_doToggleOff);

  /// Free the engine without changing the user's persisted preference.
  Future<void> suspend() => _serialExec(() async {
    _board.suspend();
    await _doShutdown();
  });

  /// Mark the shared pool as in use by a background job. Pair every call
  /// with [releasePool] in a `finally`.
  void retainPool() {
    if (isDisposed) throw StateError('Engine lifecycle is disposed');
    _poolLeases++;
  }

  /// Release a [retainPool] lease. The pool is not shut down here — the
  /// next [suspend]/[toggleOff] disposes it once no leases remain.
  void releasePool() {
    if (_poolLeases > 0) _poolLeases--;
  }

  /// Restart after [suspend] when the user preference allows it.
  Future<void> resume() => _serialExec(() async {
    if (_state == EngineState.generating || !_userWantsEngine) return;
    _resumeBoard();
    if (_state == EngineState.off) {
      _state = EngineState.idle;
      notifyListeners();
    }
  });

  void _resumeBoard() {
    unawaited(
      _board.resume().catchError((Object error) {
        debugPrint('[EngineLifecycle] Board preparation failed: $error');
      }),
    );
  }

  Future<void> _doToggleOn() async {
    if (_state == EngineState.generating) return;
    await _saveEnabled(true);
    if (isDisposed) return;
    _userWantsEngine = true;
    _preferenceLoaded = true;
    _resumeBoard();
    if (_state != EngineState.off) return;
    // Mounted boards prepare one shared process. Bulk workers are only
    // provisioned by jobs that need them; enabling analysis never starts a pool.
    _state = EngineState.idle;
    notifyListeners();
  }

  Future<void> _doToggleOff() async {
    if (_state == EngineState.generating) return;
    await _saveEnabled(false);
    if (isDisposed) return;
    _userWantsEngine = false;
    _preferenceLoaded = true;
    await _doShutdown();
  }

  Future<void> _doShutdown() async {
    if (_state == EngineState.off || _state == EngineState.generating) return;
    _board.pauseAll();
    // A leased pool belongs to a running background job — leave its workers
    // alive. On app close the orphaned engines still exit on their own:
    // stdin hits EOF when this process dies and UCI engines quit on EOF.
    if (_poolLeases == 0) {
      _pool.releaseWorkers();
    }
    _state = EngineState.off;
    notifyListeners();
  }

  /// Called when the current FEN changes; only an idle engine starts analyzing.
  void onPositionChanged(String fen) {
    if (_state != EngineState.idle) return;
    _state = EngineState.analyzing;
    _notifyListenersSafe();
  }

  /// Called when the interactive search completes.
  void onAnalysisComplete() {
    if (_state == EngineState.analyzing) {
      _state = EngineState.idle;
      _notifyListenersSafe();
    }
  }

  /// Called before generation starts.
  Future<void> enterGeneration(int threads) =>
      _serialExec(() => _doEnterGeneration(threads));

  Future<void> _doEnterGeneration(int threads) async {
    // Re-entry is idempotent: callers already in generation must not replace
    // the toggle preference captured when the mode was first entered.
    if (_state == EngineState.generating) return;
    _toggleStateBeforeGeneration = _state != EngineState.off;
    final previous = _state;
    _board.suspend();
    _state = EngineState.generating;
    notifyListeners();
    try {
      await _pool.prepareForTreeBuild(threads);
    } catch (_) {
      if (isDisposed) rethrow;
      _state = previous;
      _resumeBoard();
      notifyListeners();
      rethrow;
    }
  }

  /// Hand the engine back to interactive analysis while a build is paused.
  ///
  /// The pool and its thread configuration stay untouched — the paused build
  /// picks the same workers back up when it resumes (via [enterGeneration]);
  /// interactive analysis resumes its separate single process. Restores the state
  /// the user's toggle implies, so an engine that was off stays off.
  Future<void> pauseGeneration() => _serialExec(_doPauseGeneration);

  Future<void> _doPauseGeneration() async {
    if (_state != EngineState.generating) return;
    _resumeBoard();
    _restoreToggleState();
  }

  /// Called when generation finishes or is cancelled.
  Future<void> exitGeneration() => _serialExec(_doExitGeneration);

  Future<void> _doExitGeneration() async {
    _resumeBoard();
    // Interactive analysis no longer borrows the generation pool. Keep only
    // workers leased by another job after the build has ended.
    if (_poolLeases == 0) _pool.releaseWorkers();
    _restoreToggleState();
  }

  void _restoreToggleState() {
    _state = _toggleStateBeforeGeneration ? EngineState.idle : EngineState.off;
    notifyListeners();
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _board.suspend();
    _pool.releaseWorkers();
    super.dispose();
  }
}
