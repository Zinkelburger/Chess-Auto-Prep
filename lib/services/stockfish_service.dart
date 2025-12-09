import 'dart:async';
import 'package:flutter/foundation.dart';
import 'engine_connection.dart';
import 'stockfish_connection_factory.dart';
import '../models/engine_evaluation.dart';

class StockfishService {
  static final StockfishService _instance = StockfishService._internal();
  factory StockfishService() => _instance;

  EngineConnection? _engine;
  StreamSubscription? _engineSubscription;
  Completer<EngineEvaluation>? _analysisCompleter;
  
  final ValueNotifier<EngineEvaluation?> evaluation = ValueNotifier(null);
  final ValueNotifier<bool> isReady = ValueNotifier(false);
  final ValueNotifier<bool> isAvailable = ValueNotifier(false);
  
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
      
      // Check if Stockfish is available on this platform
      if (!StockfishConnectionFactory.isAvailable) {
        print('Stockfish is not available on this platform');
        isAvailable.value = false;
        return;
      }
      
      // Create platform-appropriate connection
      _engine = await StockfishConnectionFactory.create();
      
      if (_engine == null) {
        print('Failed to create Stockfish connection');
        isAvailable.value = false;
        return;
      }
      
      isAvailable.value = true;

      // Listen to output
      _engineSubscription = _engine?.stdout.listen(_onEngineOutput);

      // Wait for engine to be ready (loading WASM/FFI)
      await _engine?.waitForReady();
      print('Stockfish engine loaded/connected');

      // Note: uci/isready handshake is handled inside waitForReady()
      
      // Set multithreading if available (standard UCI option 'Threads')
      // We'll try to set it to 4 threads by default for better performance
      _sendCommand('setoption name Threads value 4');
      _sendCommand('setoption name Hash value 128'); // 128MB hash
      
    } catch (e) {
      print('Failed to initialize Stockfish: $e');
      isAvailable.value = false;
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
    } else if (line.startsWith('bestmove')) {
      _isAnalyzing = false;
      if (_analysisCompleter != null && !_analysisCompleter!.isCompleted) {
        _analysisCompleter!.complete(evaluation.value ?? EngineEvaluation());
        _analysisCompleter = null;
      }
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
    if (_analysisCompleter != null && !_analysisCompleter!.isCompleted) {
      _analysisCompleter!.completeError(Exception('Analysis stopped'));
      _analysisCompleter = null;
    }
  }

  Future<EngineEvaluation> getEvaluation(String fen, {int depth = 15}) async {
    if (_engine == null) throw Exception('Engine not initialized');
    
    // Wait for engine to be ready
    if (!isReady.value) {
      print('Waiting for Stockfish to be ready (Analysis request)...');
      
      // Increased timeout to 30 seconds and added debug info
      int waited = 0;
      // 300 iterations * 100ms = 30 seconds
      while (!isReady.value && waited < 300) {
        if (waited % 50 == 0) {
           print('[StockfishService] Still waiting for ready... (waited ${waited * 0.1}s)');
        }
        await Future.delayed(const Duration(milliseconds: 100));
        waited++;
      }
      
      if (!isReady.value) {
        throw Exception('Stockfish engine not ready after 30 seconds. Current state: isReady=${isReady.value}, isAvailable=${isAvailable.value}, isAnalyzing=$_isAnalyzing');
      }
      print('Stockfish is ready!');
    }
    
    // Cancel any ongoing analysis
    if (_isAnalyzing) {
      stopAnalysis();
    }

    _analysisCompleter = Completer<EngineEvaluation>();
    _isAnalyzing = true;
    
    // Reset evaluation
    evaluation.value = null;
    
    final parts = fen.split(' ');
    if (parts.length >= 2) {
      _isWhiteTurn = parts[1] == 'w';
    }
    
    _sendCommand('stop'); // Ensure stopped
    _sendCommand('position fen $fen');
    _sendCommand('go depth $depth');
    
    // Add a timeout to prevent hanging forever
    return _analysisCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        print('Analysis timed out for FEN: $fen');
        _isAnalyzing = false;
        return evaluation.value ?? EngineEvaluation();
      },
    );
  }

  void dispose() {
    _isDisposed = true;
    _sendCommand('quit');
    _engineSubscription?.cancel();
    _engine?.dispose();
  }
}
