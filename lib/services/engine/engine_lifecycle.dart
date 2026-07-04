/// Single source of truth for engine state across analysis and generation.
///
/// Replaces the implicit lifecycle spread across MainScreen,
/// UnifiedEnginePane, RepertoireController, and RepertoireGenerationTab.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis_service.dart';
import 'stockfish_pool.dart';

enum EngineState { off, idle, analyzing, generating }

class EngineLifecycle extends ChangeNotifier {
  /// Application-wide shared instance.
  static final EngineLifecycle instance = EngineLifecycle._();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  EngineLifecycle.fresh() : this._();

  EngineLifecycle._();

  final StockfishPool _pool = StockfishPool.instance;
  final AnalysisService _analysis = AnalysisService.instance;

  EngineState _state = EngineState.off;
  EngineState get state => _state;

  bool _toggleStateBeforeGeneration = false;

  void _notifyListenersSafe() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      notifyListeners();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
    }
  }

  Future<void> _queueTail = Future.value();

  static const _toggleKey = 'engine_lifecycle.toggle_on';

  /// When true, [toggleOn]/[toggleOff] skip pool I/O (unit tests only).
  @visibleForTesting
  static bool testMode = false;

  Future<void> _serialExec(Future<void> Function() fn) async {
    _queueTail = _queueTail.then((_) => fn());
    await _queueTail;
  }

  /// Load persisted toggle state. Call once at app startup.
  ///
  /// Engine is **on** by default; only a stored `false` disables it.
  Future<void> loadPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    final wasOn = prefs.getBool(_toggleKey) ?? true;
    if (wasOn) {
      await _doToggleOn();
    }
  }

  Future<void> toggleOn() => _serialExec(_doToggleOn);
  Future<void> toggleOff() => _serialExec(_doToggleOff);

  Future<void> _doToggleOn() async {
    if (_state != EngineState.off) return;
    // Workers are spawned lazily on first use (ensureWorkers is called by
    // AnalysisService, EngineWeaknessService, etc. before any eval work).
    // This avoids N Stockfish processes sitting idle after app launch.
    _state = EngineState.idle;
    _persistToggle(true);
    notifyListeners();
  }

  Future<void> _doToggleOff() async {
    if (_state == EngineState.off) return;
    if (_state == EngineState.generating) return;
    _analysis.cancel();
    if (!testMode) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _pool.dispose();
    _state = EngineState.off;
    _persistToggle(false);
    notifyListeners();
  }

  /// Called when the current FEN changes and state is idle/analyzing.
  void onPositionChanged(String fen) {
    if (_state == EngineState.off || _state == EngineState.generating) return;
    if (_state == EngineState.analyzing) return;
    _state = EngineState.analyzing;
    _notifyListenersSafe();
  }

  /// Called when AnalysisService completes.
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
    _toggleStateBeforeGeneration = _state != EngineState.off;
    _analysis.cancel();
    if (!testMode) {
      await _pool.prepareForTreeBuild(threads);
    }
    _state = EngineState.generating;
    notifyListeners();
  }

  /// Called when generation finishes or is cancelled.
  Future<void> exitGeneration() => _serialExec(_doExitGeneration);

  Future<void> _doExitGeneration() async {
    if (_toggleStateBeforeGeneration) {
      if (!testMode && _pool.workerCount > 0) {
        await _pool.reconfigureAllWorkers(1);
      }
      _state = EngineState.idle;
    } else {
      _pool.dispose();
      _state = EngineState.off;
    }
    notifyListeners();
  }

  Future<void> _persistToggle(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_toggleKey, on);
    } catch (e) {
      debugPrint('[EngineLifecycle] Failed to persist toggle: $e');
    }
  }

  /// Resets singleton state between tests. Does not notify listeners.
  @visibleForTesting
  void resetForTest() {
    _analysis.cancel();
    _pool.dispose();
    _state = EngineState.off;
    _toggleStateBeforeGeneration = false;
    _queueTail = Future.value();
    testMode = false;
  }
}
