/// Engine settings model for configuring analysis parameters
library;

import 'package:flutter/foundation.dart';
import '../utils/system_info.dart';

class EngineSettings with ChangeNotifier {
  // ── Stockfish settings ────────────────────────────────────────────────

  /// Number of parallel Stockfish workers (each: 1 thread, 64 MB hash).
  /// Defaults to half the logical cores, minimum 1.
  int _workers = (getLogicalCores() ~/ 2).clamp(1, getLogicalCores());
  int get workers => _workers;
  set workers(int value) {
    final clamped = value.clamp(1, systemCores);
    if (clamped != _workers) {
      _workers = clamped;
      notifyListeners();
    }
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
    _workers = (systemCores ~/ 2).clamp(1, systemCores);
    _depth = 20;
    _easeDepth = 18;
    _multiPv = 3;
    _maxAnalysisMoves = 8;
    _showStockfish = true;
    _showMaia = true;
    _showEase = true;
    _showProbability = true;
    _probabilityStartMoves = '';
    _maiaElo = 2100;
    notifyListeners();
  }
}
