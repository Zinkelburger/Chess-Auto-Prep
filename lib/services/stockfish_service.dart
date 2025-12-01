import 'dart:async';
import 'package:flutter/foundation.dart';
import 'engine_connection.dart';
import 'stockfish_package_connection.dart';
import 'process_connection_factory.dart';
import '../models/engine_evaluation.dart';

class StockfishService {
  static final StockfishService _instance = StockfishService._internal();
  factory StockfishService() => _instance;

  EngineConnection? _engine;
  StreamSubscription? _engineSubscription;
  
  final ValueNotifier<EngineEvaluation?> evaluation = ValueNotifier(null);
  final ValueNotifier<bool> isReady = ValueNotifier(false);
  
  bool _isDisposed = false;
  bool _isAnalyzing = false;
  String _currentFen = '';
  bool _isWhiteTurn = true;

  StockfishService._internal() {
    _initEngine();
  }

  Future<void> _initEngine() async {
    try {
      print('Initializing Stockfish...');
      
      if (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
        // Use package:stockfish for Web and Mobile (FFI/WASM)
        print('Using Stockfish Package (FFI/WASM)');
        _engine = StockfishPackageConnection();
      } else {
        // Use bundled binary for Desktop
        print('Using Stockfish Process (Bundled Binary)');
        _engine = await ProcessConnection.create();
      }

      // Listen to output
      _engineSubscription = _engine?.stdout.listen(_onEngineOutput);

      // Wait for engine to be ready (loading WASM/FFI)
      await _engine?.waitForReady();
      print('Stockfish engine loaded/connected');

      // Initialize UCI
      _sendCommand('uci');
      _sendCommand('isready');
      
    } catch (e) {
      print('Failed to initialize Stockfish: $e');
    }
  }

  void _restoreAnalysis() {
    if (_isAnalyzing && _currentFen.isNotEmpty) {
      _sendCommand('position fen $_currentFen');
      _sendCommand('go depth 20');
    }
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
      _restoreAnalysis(); // Restore if we were waiting for readyok
    } else if (line.startsWith('info')) {
      _parseInfo(line);
    }
  }

  void _parseInfo(String line) {
    // info depth 10 seldepth 15 score cp 50 nodes 12345 pv e2e4 e7e5
    if (!line.contains('score') && !line.contains('pv')) return;

    int? depth;
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
      } else if (part == 'score' && i + 2 < parts.length) {
        final type = parts[i + 1]; // cp or mate
        final val = int.tryParse(parts[i + 2]);
        
        if (type == 'cp' && val != null) {
          // Normalize score to White's perspective
          scoreCp = _isWhiteTurn ? val : -val;
        } else if (type == 'mate' && val != null) {
          scoreMate = _isWhiteTurn ? val : -val;
        }
      } else if (part == 'nodes' && i + 1 < parts.length) {
        nodes = int.tryParse(parts[i + 1]) ?? 0;
      } else if (part == 'nps' && i + 1 < parts.length) {
        nps = int.tryParse(parts[i + 1]) ?? 0;
      } else if (part == 'pv' && i + 1 < parts.length) {
        // PV is the rest of the line
        pv = parts.sublist(i + 1);
        break; // PV is usually the last part
      }
    }

    if (depth != null) {
      final current = evaluation.value ?? EngineEvaluation();
      
      // Only update if we have useful info (score or pv)
      if (scoreCp != null || scoreMate != null || pv.isNotEmpty) {
        evaluation.value = current.copyWith(
          depth: depth,
          scoreCp: scoreCp ?? current.scoreCp,
          scoreMate: scoreMate ?? current.scoreMate,
          pv: pv.isNotEmpty ? pv : current.pv,
          nodes: nodes > 0 ? nodes : current.nodes,
          nps: nps > 0 ? nps : current.nps,
        );
      }
    }
  }

  void startAnalysis(String fen) {
    if (_currentFen == fen && _isAnalyzing) return;
    
    _currentFen = fen;
    _isAnalyzing = true;
    
    final parts = fen.split(' ');
    if (parts.length >= 2) {
      _isWhiteTurn = parts[1] == 'w';
    }

    evaluation.value = null;
    
    _sendCommand('stop');
    _sendCommand('position fen $fen');
    _sendCommand('go depth 20');
  }

  void stopAnalysis() {
    _sendCommand('stop');
    _isAnalyzing = false;
  }

  void dispose() {
    _isDisposed = true;
    _sendCommand('quit');
    _engineSubscription?.cancel();
    _engine?.dispose();
  }
}
