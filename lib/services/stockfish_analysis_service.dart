/// Stockfish analysis service with multi-PV and configurable settings
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'engine_connection.dart';
import 'stockfish_connection_factory.dart';
import '../models/engine_settings.dart';

/// Represents a single analysis line (PV)
class AnalysisLine {
  final int pvNumber;
  final int depth;
  final int? scoreCp;
  final int? scoreMate;
  final List<String> pv;
  final int nodes;
  final int nps;

  AnalysisLine({
    required this.pvNumber,
    required this.depth,
    this.scoreCp,
    this.scoreMate,
    this.pv = const [],
    this.nodes = 0,
    this.nps = 0,
  });

  String get scoreString {
    if (scoreMate != null) {
      return 'M${scoreMate! > 0 ? scoreMate : scoreMate}';
    }
    if (scoreCp != null) {
      final double eval = scoreCp! / 100.0;
      return eval >= 0 ? '+${eval.toStringAsFixed(2)}' : eval.toStringAsFixed(2);
    }
    return '...';
  }

  /// Get effective centipawn score (converts mate to large cp value)
  int get effectiveCp {
    if (scoreMate != null) {
      return scoreMate! > 0 ? 10000 - scoreMate!.abs() : -(10000 - scoreMate!.abs());
    }
    return scoreCp ?? 0;
  }

  AnalysisLine copyWith({
    int? pvNumber,
    int? depth,
    int? scoreCp,
    int? scoreMate,
    List<String>? pv,
    int? nodes,
    int? nps,
  }) {
    return AnalysisLine(
      pvNumber: pvNumber ?? this.pvNumber,
      depth: depth ?? this.depth,
      scoreCp: scoreCp ?? this.scoreCp,
      scoreMate: scoreMate ?? this.scoreMate,
      pv: pv ?? this.pv,
      nodes: nodes ?? this.nodes,
      nps: nps ?? this.nps,
    );
  }
}

/// Complete analysis result with multiple lines
class AnalysisResult {
  final List<AnalysisLine> lines;
  final int depth;
  final int nodes;
  final int nps;
  final bool isComplete;

  AnalysisResult({
    this.lines = const [],
    this.depth = 0,
    this.nodes = 0,
    this.nps = 0,
    this.isComplete = false,
  });

  AnalysisResult copyWith({
    List<AnalysisLine>? lines,
    int? depth,
    int? nodes,
    int? nps,
    bool? isComplete,
  }) {
    return AnalysisResult(
      lines: lines ?? this.lines,
      depth: depth ?? this.depth,
      nodes: nodes ?? this.nodes,
      nps: nps ?? this.nps,
      isComplete: isComplete ?? this.isComplete,
    );
  }
}

class StockfishAnalysisService {
  static final StockfishAnalysisService _instance = StockfishAnalysisService._internal();
  factory StockfishAnalysisService() => _instance;

  EngineConnection? _engine;
  StreamSubscription? _engineSubscription;
  final EngineSettings _settings = EngineSettings();

  final ValueNotifier<AnalysisResult> analysis = ValueNotifier(AnalysisResult());
  final ValueNotifier<bool> isReady = ValueNotifier(false);
  final ValueNotifier<bool> isAvailable = ValueNotifier(false);
  final ValueNotifier<bool> isAnalyzing = ValueNotifier(false);
  final ValueNotifier<String> status = ValueNotifier('Initializing...');

  bool _isDisposed = false;
  String _currentFen = '';
  bool _isWhiteTurn = true;
  int _currentMultiPv = 3;

  // Temp storage for building lines during analysis
  final Map<int, AnalysisLine> _currentLines = {};

  StockfishAnalysisService._internal() {
    _initEngine();
  }

  Future<void> _initEngine() async {
    try {
      status.value = 'Initializing Stockfish...';

      if (!StockfishConnectionFactory.isAvailable) {
        status.value = 'Stockfish not available on this platform';
        isAvailable.value = false;
        return;
      }

      _engine = await StockfishConnectionFactory.create();

      if (_engine == null) {
        status.value = 'Failed to create Stockfish connection';
        isAvailable.value = false;
        return;
      }

      isAvailable.value = true;

      _engineSubscription = _engine?.stdout.listen(_onEngineOutput);

      await _engine?.waitForReady();
      
      // Apply initial settings
      await _applySettings();
      
      isReady.value = true;
      status.value = 'Ready';

    } catch (e) {
      status.value = 'Error: $e';
      isAvailable.value = false;
    }
  }

  Future<void> _applySettings() async {
    if (_engine == null) return;
    
    _engine!.sendCommand('setoption name Threads value ${_settings.cores}');
    _engine!.sendCommand('setoption name Hash value ${_settings.hashMb}');
    _engine!.sendCommand('setoption name MultiPV value ${_settings.multiPv}');
    _currentMultiPv = _settings.multiPv;
    _engine!.sendCommand('isready');
  }

  void updateSettings() {
    _applySettings();
  }

  void _sendCommand(String command) {
    if (_isDisposed || _engine == null) return;
    _engine!.sendCommand(command);
  }

  void _onEngineOutput(String line) {
    line = line.trim();
    if (line.isEmpty) return;

    if (line == 'readyok') {
      isReady.value = true;
    } else if (line.startsWith('info')) {
      _parseInfo(line);
    } else if (line.startsWith('bestmove')) {
      isAnalyzing.value = false;
      status.value = 'Analysis complete';
      
      // Mark as complete
      analysis.value = analysis.value.copyWith(isComplete: true);
    }
  }

  void _parseInfo(String line) {
    if (!line.contains('score') && !line.contains('pv')) return;

    int? depth;
    int? multipv;
    int? scoreCp;
    int? scoreMate;
    List<String> pv = [];
    int nodes = 0;
    int nps = 0;

    final parts = line.split(' ');
    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];

      if (part == 'depth' && i + 1 < parts.length) {
        depth = int.tryParse(parts[i + 1]);
      } else if (part == 'multipv' && i + 1 < parts.length) {
        multipv = int.tryParse(parts[i + 1]);
      } else if (part == 'score' && i + 2 < parts.length) {
        final type = parts[i + 1];
        final val = int.tryParse(parts[i + 2]);

        if (type == 'cp' && val != null) {
          scoreCp = _isWhiteTurn ? val : -val;
        } else if (type == 'mate' && val != null) {
          scoreMate = _isWhiteTurn ? val : -val;
        }
      } else if (part == 'nodes' && i + 1 < parts.length) {
        nodes = int.tryParse(parts[i + 1]) ?? 0;
      } else if (part == 'nps' && i + 1 < parts.length) {
        nps = int.tryParse(parts[i + 1]) ?? 0;
      } else if (part == 'pv' && i + 1 < parts.length) {
        pv = parts.sublist(i + 1);
        break;
      }
    }

    if (depth != null && multipv != null) {
      final lineNum = multipv;
      
      _currentLines[lineNum] = AnalysisLine(
        pvNumber: lineNum,
        depth: depth,
        scoreCp: scoreCp,
        scoreMate: scoreMate,
        pv: pv,
        nodes: nodes,
        nps: nps,
      );

      // Update analysis with all current lines
      final sortedLines = _currentLines.values.toList()
        ..sort((a, b) => a.pvNumber.compareTo(b.pvNumber));

      analysis.value = AnalysisResult(
        lines: sortedLines,
        depth: depth,
        nodes: nodes,
        nps: nps,
      );

      status.value = 'Depth $depth • ${_formatNodes(nodes)} nodes • ${_formatNps(nps)} n/s';
    }
  }

  String _formatNodes(int nodes) {
    if (nodes >= 1000000) {
      return '${(nodes / 1000000).toStringAsFixed(1)}M';
    } else if (nodes >= 1000) {
      return '${(nodes / 1000).toStringAsFixed(1)}k';
    }
    return nodes.toString();
  }

  String _formatNps(int nps) {
    if (nps >= 1000000) {
      return '${(nps / 1000000).toStringAsFixed(1)}M';
    } else if (nps >= 1000) {
      return '${(nps / 1000).toStringAsFixed(0)}k';
    }
    return nps.toString();
  }

  void startAnalysis(String fen, {int? depth, int? multiPv}) {
    if (!isReady.value || !isAvailable.value) return;
    
    _currentFen = fen;
    isAnalyzing.value = true;
    _currentLines.clear();
    analysis.value = AnalysisResult();

    final parts = fen.split(' ');
    if (parts.length >= 2) {
      _isWhiteTurn = parts[1] == 'w';
    }

    // Update MultiPV if changed
    final targetMultiPv = multiPv ?? _settings.multiPv;
    if (targetMultiPv != _currentMultiPv) {
      _sendCommand('setoption name MultiPV value $targetMultiPv');
      _currentMultiPv = targetMultiPv;
    }

    final targetDepth = depth ?? _settings.depth;

    status.value = 'Analyzing...';
    _sendCommand('stop');
    _sendCommand('position fen $fen');
    _sendCommand('go depth $targetDepth');
  }

  void stopAnalysis() {
    _sendCommand('stop');
    isAnalyzing.value = false;
    status.value = 'Stopped';
  }

  void dispose() {
    _isDisposed = true;
    _sendCommand('quit');
    _engineSubscription?.cancel();
    _engine?.dispose();
  }
}

