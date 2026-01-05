/// Engine settings model for configuring analysis parameters
library;

import 'package:flutter/foundation.dart';

class EngineSettings with ChangeNotifier {
  // Stockfish settings
  int _cores = 2;
  int get cores => _cores;
  set cores(int value) {
    if (value != _cores && value >= 1 && value <= 32) {
      _cores = value;
      notifyListeners();
    }
  }

  int _hashMb = 256;
  int get hashMb => _hashMb;
  set hashMb(int value) {
    if (value != _hashMb && value >= 16 && value <= 16384) {
      _hashMb = value;
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

  int _multiPv = 3;
  int get multiPv => _multiPv;
  set multiPv(int value) {
    if (value != _multiPv && value >= 1 && value <= 10) {
      _multiPv = value;
      notifyListeners();
    }
  }

  // Panel visibility toggles
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

  bool _showCoherence = true;
  bool get showCoherence => _showCoherence;
  set showCoherence(bool value) {
    if (value != _showCoherence) {
      _showCoherence = value;
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

  // Probability settings - starting moves (e.g., "1. d4 d5 2. Nf3")
  String _probabilityStartMoves = '';
  String get probabilityStartMoves => _probabilityStartMoves;
  set probabilityStartMoves(String value) {
    if (value != _probabilityStartMoves) {
      _probabilityStartMoves = value;
      notifyListeners();
    }
  }

  // Maia ELO setting
  int _maiaElo = 1900;
  int get maiaElo => _maiaElo;
  set maiaElo(int value) {
    if (value != _maiaElo && value >= 1100 && value <= 1900) {
      _maiaElo = value;
      notifyListeners();
    }
  }

  // Singleton instance
  static final EngineSettings _instance = EngineSettings._internal();
  factory EngineSettings() => _instance;
  EngineSettings._internal();

  /// Reset all settings to defaults
  void resetToDefaults() {
    _cores = 2;
    _hashMb = 256;
    _depth = 20;
    _multiPv = 3;
    _showStockfish = true;
    _showMaia = true;
    _showEase = true;
    _showCoherence = true;
    _showProbability = true;
    _probabilityStartMoves = '';
    _maiaElo = 1900;
    notifyListeners();
  }
}

