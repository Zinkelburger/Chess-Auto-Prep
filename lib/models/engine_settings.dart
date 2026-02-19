/// Engine settings model for configuring analysis parameters
library;

import 'package:flutter/foundation.dart';
import '../utils/system_info.dart';

class EngineSettings with ChangeNotifier {
  // ── Stockfish settings ────────────────────────────────────────────────

  /// Maximum number of parallel Stockfish workers (each uses 1 thread).
  ///
  /// Always reserves 2 cores: 1 for the host OS and 1 for the Flutter
  /// UI / main isolate.  The pool further constrains the *actual* count
  /// from live RAM headroom at spawn time, so this is a **ceiling**.
  int get cores => (systemCores - 2).clamp(1, systemCores);

  /// Maximum Stockfish hash budget in MB, derived from [maxSystemLoad]%
  /// of total system RAM.
  ///
  /// The pool computes a dynamic hash per worker from actual free RAM;
  /// this value acts as an absolute **ceiling**.
  int get hashMb =>
      ((systemRamMb * _maxSystemLoad) ~/ 100).clamp(64, systemRamMb);

  /// Per-worker hash ceiling = total budget / (workers + 1).
  ///
  /// The extra +1 reserves a share for the interactive analysis engine
  /// that runs alongside the pool.  The pool may assign *less* based on
  /// live RAM headroom.
  int get hashPerWorker {
    final c = cores;
    if (c <= 0) return hashMb;
    return (hashMb / (c + 1)).floor().clamp(16, hashMb);
  }

  int _depth = 20;
  int get depth => _depth;
  set depth(int value) {
    if (value != _depth && value >= 1 && value <= 99) {
      _depth = value;
      notifyListeners();
    }
  }

  /// Depth used for ease sub-evaluations (each Maia candidate move).
  /// Lower than [depth] because ease evaluates multiple positions per move,
  /// so the cost multiplies quickly.
  int _easeDepth = 18;
  int get easeDepth => _easeDepth;
  set easeDepth(int value) {
    if (value != _easeDepth && value >= 1 && value <= 99) {
      _easeDepth = value;
      notifyListeners();
    }
  }

  int _multiPv = 3;
  int get multiPv => _multiPv;
  set multiPv(int value) {
    if (value != _multiPv && value >= 1 && value <= 10) {
      _multiPv = value;
      notifyListeners();
    }
  }

  /// Load ceiling (%) used by the dynamic resource allocator.
  ///
  /// RAM headroom = `maxSystemLoad% × totalRam − usedRam`.
  /// CPU budget = cores whose load stays below this threshold.
  /// Workers are spawned in parallel; the budget is computed upfront so
  /// the pool never drives the system above this ceiling.
  int _maxSystemLoad = 80;
  int get maxSystemLoad => _maxSystemLoad;
  set maxSystemLoad(int value) {
    if (value != _maxSystemLoad && value >= 50 && value <= 100) {
      _maxSystemLoad = value;
      notifyListeners();
    }
  }

  /// Maximum total moves to display in the analysis table.
  /// Stockfish MultiPV lines fill guaranteed slots; remaining slots are
  /// filled by the highest-probability Maia + DB candidates.
  int _maxAnalysisMoves = 8;
  int get maxAnalysisMoves => _maxAnalysisMoves;
  set maxAnalysisMoves(int value) {
    if (value != _maxAnalysisMoves && value >= 3 && value <= 20) {
      _maxAnalysisMoves = value;
      notifyListeners();
    }
  }

  // ── Panel visibility toggles ──────────────────────────────────────────

  bool _showStockfish = true;
  bool get showStockfish => _showStockfish;
  set showStockfish(bool value) {
    if (value != _showStockfish) {
      _showStockfish = value;
      notifyListeners();
    }
  }

  bool _showMaia = true;
  bool get showMaia => _showMaia;
  set showMaia(bool value) {
    if (value != _showMaia) {
      _showMaia = value;
      notifyListeners();
    }
  }

  bool _showEase = true;
  bool get showEase => _showEase;
  set showEase(bool value) {
    if (value != _showEase) {
      _showEase = value;
      notifyListeners();
    }
  }

  bool _showProbability = true;
  bool get showProbability => _showProbability;
  set showProbability(bool value) {
    if (value != _showProbability) {
      _showProbability = value;
      notifyListeners();
    }
  }

  // ── Probability settings ──────────────────────────────────────────────

  String _probabilityStartMoves = '';
  String get probabilityStartMoves => _probabilityStartMoves;
  set probabilityStartMoves(String value) {
    if (value != _probabilityStartMoves) {
      _probabilityStartMoves = value;
      notifyListeners();
    }
  }

  // ── Maia ELO setting ──────────────────────────────────────────────────

  int _maiaElo = 2100;
  int get maiaElo => _maiaElo;
  set maiaElo(int value) {
    if (value != _maiaElo && value >= 1100 && value <= 2100) {
      _maiaElo = value;
      notifyListeners();
    }
  }

  // ── Singleton + system detection ─────────────────────────────────────

  /// Detected system RAM in MB.
  static final int systemRamMb = getSystemRamMb();

  /// Detected logical CPU cores.
  static final int systemCores = getLogicalCores();

  static final EngineSettings _instance = EngineSettings._internal();
  factory EngineSettings() => _instance;
  EngineSettings._internal();

  /// Reset all settings to defaults
  void resetToDefaults() {
    _depth = 20;
    _easeDepth = 18;
    _multiPv = 3;
    _maxAnalysisMoves = 8;
    _maxSystemLoad = 80;
    _showStockfish = true;
    _showMaia = true;
    _showEase = true;
    _showProbability = true;
    _probabilityStartMoves = '';
    _maiaElo = 2100;
    notifyListeners();
  }
}
