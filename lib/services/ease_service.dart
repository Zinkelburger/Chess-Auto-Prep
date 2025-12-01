import 'dart:async';
import 'dart:math' as math;
import 'package:chess/chess.dart' as chess;
import 'package:flutter/foundation.dart';

import 'engine_connection.dart';
import 'process_connection_factory.dart';
import 'maia_service.dart';

// Tuning parameters for Ease
const double ALPHA = 1/3;
const double BETA = 1.5;

class EaseResult {
  final double ease;
  final double rawEase;
  final double safetyFactor;
  final String bestMove;
  final double maxQ;
  final List<EaseMove> moves;
  final List<MaiaMove> maiaMoves;

  EaseResult({
    required this.ease,
    required this.rawEase,
    required this.safetyFactor,
    required this.bestMove,
    required this.maxQ,
    required this.moves,
    required this.maiaMoves,
  });
}

class EaseMove {
  final String uci;
  final double prob;
  final int score;
  final double qVal;
  final double regret;

  EaseMove({
    required this.uci,
    required this.prob,
    required this.score,
    required this.qVal,
    required this.regret,
  });
}

class MaiaMove {
  final String uci;
  final double prob;

  MaiaMove({required this.uci, required this.prob});
}

class EaseService {
  static final EaseService _instance = EaseService._internal();
  factory EaseService() => _instance;

  // Notifier for status updates
  final ValueNotifier<String> status = ValueNotifier('Idle');
  final ValueNotifier<EaseResult?> currentResult = ValueNotifier(null);
  
  EngineConnection? _engine;
  StreamSubscription? _engineSubscription;
  bool _isAnalyzing = false;
  
  // State for the current evaluation request
  Completer<EngineEvalResult>? _currentEvalCompleter;
  int? _currentEvalBestScore;
  String? _currentEvalFen;

  EaseService._internal();

  Future<void> calculateEase(String fen) async {
    if (_isAnalyzing) return; // Simple mutex
    _isAnalyzing = true;
    status.value = 'Calculating...';
    currentResult.value = null;

    try {
      // 1. Maia Inference
      status.value = 'Running Maia...';
      final maiaProbs = await MaiaService().evaluate(fen, 1800);
      
      final sortedMoves = maiaProbs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      final List<MaiaMove> topMaiaMoves = [];
      final List<String> candidateUcis = [];
      double cumulativeProb = 0.0;

      for (final entry in sortedMoves) {
        final prob = entry.value;
        if (topMaiaMoves.length < 5) {
          topMaiaMoves.add(MaiaMove(uci: entry.key, prob: prob));
        }
        
        if (prob < 0.01) continue;
        
        candidateUcis.add(entry.key);
        cumulativeProb += prob;
        if (cumulativeProb > 0.90) break;
      }
      
      if (candidateUcis.isEmpty) {
        status.value = 'No candidate moves found';
        _isAnalyzing = false;
        return;
      }

      // 2. Engine Analysis
      status.value = 'Starting Engine...';
      await _ensureEngine();
      
      // 2a. Root Eval (Ceiling)
      status.value = 'Analyzing Root...';
      final rootEval = await _evaluateFen(fen, 12);
      final maxQ = _scoreToQ(rootEval.score);
      final bestMove = rootEval.bestMove ?? '-';
      final safetyFactor = _calculateSafetyFactor(rootEval.score);

      // 2b. Candidate Evals
      status.value = 'Analyzing Candidates...';
      final List<EaseMove> results = [];
      double sumWeightedRegret = 0.0;
      
      final chessGame = chess.Chess.fromFEN(fen);
      
      for (final uci in candidateUcis) {
        // Make move
        final from = uci.substring(0, 2);
        final to = uci.substring(2, 4);
        String? promotion;
        if (uci.length > 4) promotion = uci.substring(4);
        
        final moveMap = {'from': from, 'to': to};
        if (promotion != null) moveMap['promotion'] = promotion;
        
        // Push
        if (!chessGame.move(moveMap)) {
           print('Failed to make move $uci');
           continue;
        }
        
        final nextFen = chessGame.fen;
        
        // Eval
        final eval = await _evaluateFen(nextFen, 10);
        
        // Pop
        chessGame.undo();
        
        final score = -eval.score; 
        final qVal = _scoreToQ(score);
        final prob = maiaProbs[uci] ?? 0.0;
        
        final regret = math.max(0.0, maxQ - qVal);
        final term = math.pow(prob, BETA) * regret;
        sumWeightedRegret += term;
        
        results.append(EaseMove(
          uci: uci,
          prob: prob,
          score: score,
          qVal: qVal,
          regret: regret,
        ));
      }

      // 3. Ease Calculation
      final rawEase = 1.0 - math.pow(sumWeightedRegret / 2, ALPHA);
      final finalEase = rawEase * safetyFactor;
      
      currentResult.value = EaseResult(
        ease: finalEase,
        rawEase: rawEase,
        safetyFactor: safetyFactor,
        bestMove: bestMove,
        maxQ: maxQ,
        moves: results,
        maiaMoves: topMaiaMoves,
      );
      
      status.value = 'Calculation Complete';

    } catch (e) {
      print('Ease Error: $e');
      status.value = 'Error: $e';
    } finally {
      _isAnalyzing = false;
    }
  }
  
  Future<EngineEvalResult> _evaluateFen(String fenToEval, int depth) async {
    if (_currentEvalCompleter != null && !_currentEvalCompleter!.isCompleted) {
       _currentEvalCompleter!.completeError('Cancelled');
    }
    
    _currentEvalCompleter = Completer<EngineEvalResult>();
    _currentEvalBestScore = null;
    _currentEvalFen = fenToEval;
    
    _engine!.sendCommand('stop');
    _engine!.sendCommand('position fen $fenToEval');
    _engine!.sendCommand('go depth $depth');
    
    return _currentEvalCompleter!.future;
  }

  Future<void> _ensureEngine() async {
    if (_engine != null) return;
    _engine = await ProcessConnection.create();
    
    // Set up permanent subscription
    _engineSubscription = _engine!.stdout.listen((line) {
      _handleEngineOutput(line);
    });

    // Init UCI
    _engine!.sendCommand('uci');
    _engine!.sendCommand('isready');
  }
  
  void _handleEngineOutput(String line) {
    line = line.trim();
    if (_currentEvalCompleter == null || _currentEvalCompleter!.isCompleted) return;

    if (line.startsWith('info') && line.contains('score')) {
      final score = _parseScore(line, _currentEvalFen ?? '');
      if (score != null) _currentEvalBestScore = score;
    }
    
    if (line.startsWith('bestmove')) {
       final parts = line.split(' ');
       String? bestPv;
       if (parts.length > 1) bestPv = parts[1];
       
       _currentEvalCompleter?.complete(
         EngineEvalResult(score: _currentEvalBestScore ?? 0, bestMove: bestPv)
       );
       _currentEvalCompleter = null;
    }
  }
  
  // Helpers
  int? _parseScore(String line, String fen) {
    try {
      final parts = line.split(' ');
      final scoreIdx = parts.indexOf('score');
      if (scoreIdx == -1 || scoreIdx + 2 >= parts.length) return null;
      
      final type = parts[scoreIdx + 1];
      final val = int.tryParse(parts[scoreIdx + 2]);
      if (val == null) return null;
      
      if (type == 'mate') {
        return val > 0 ? 10000 - val : -10000 - val;
      } else if (type == 'cp') {
        return val;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }
  
  double _scoreToQ(int cp) {
    // Q = 2 * WinProb - 1
    if (cp.abs() > 9000) return cp > 0 ? 1.0 : -1.0;
    
    final winProb = 1.0 / (1.0 + math.exp(-0.004 * cp));
    return 2.0 * winProb - 1.0;
  }
  
  double _calculateSafetyFactor(int cp) {
    if (cp >= -50) return 1.0;
    final val = 1.0 + (cp + 50) / 1000.0;
    return math.max(0.0, val);
  }

  void dispose() {
    _engineSubscription?.cancel();
    _engine?.dispose();
    _engine = null;
    _currentEvalCompleter = null;
  }
}

class EngineEvalResult {
  final int score;
  final String? bestMove;
  EngineEvalResult({required this.score, this.bestMove});
}

extension ListAppend<T> on List<T> {
  void append(T item) => add(item);
}
