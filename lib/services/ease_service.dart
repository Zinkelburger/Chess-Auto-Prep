import 'dart:async';
import 'dart:math' as math;
import 'package:chess/chess.dart' as chess;
import 'package:flutter/foundation.dart';

import 'engine_connection.dart';
import 'stockfish_connection_factory.dart';
import 'maia_factory.dart';
import '../models/engine_evaluation.dart';

// Tuning parameters for Ease
const double _kAlpha = 1/3;
const double _kBeta = 1.5;

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
  final double? moveEase;

  EaseMove({
    required this.uci,
    required this.prob,
    required this.score,
    required this.qVal,
    required this.regret,
    this.moveEase,
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

  final ValueNotifier<String> status = ValueNotifier('Idle');
  final ValueNotifier<EaseResult?> currentResult = ValueNotifier(null);
  
  EngineConnection? _engine;
  StreamSubscription? _engineSubscription;
  bool _isAnalyzing = false;
  
  // State for the current evaluation request
  Completer<EngineEvaluation>? _currentEvalCompleter;
  int? _currentEvalBestScore;
  List<int>? _currentEvalWdl;
  String? _currentEvalBestMove;

  EaseService._internal();

  Future<void> calculateEase(String fen) async {
    if (_isAnalyzing) return;
    _isAnalyzing = true;
    status.value = 'Calculating...';
    currentResult.value = null;

    try {
      // Check if Maia is available
      if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
        status.value = 'Maia not available on this platform';
        _isAnalyzing = false;
        return;
      }
      
      // 1. Maia Inference
      status.value = 'Running Maia...';
      final maiaProbs = await MaiaFactory.instance!.evaluate(fen, 1900);
      
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
      final maxQ = _scoreToQ(rootEval.effectiveCp);
      final bestMove = rootEval.bestMove ?? '-';
      final safetyFactor = 1.0; // Feature disabled

      // 2b. Candidate Evals
      status.value = 'Analyzing Candidates...';
      final List<EaseMove> results = [];
      double sumWeightedRegret = 0.0;
      
      final chessGame = chess.Chess.fromFEN(fen);
      
      for (final uci in candidateUcis) {
        final from = uci.substring(0, 2);
        final to = uci.substring(2, 4);
        String? promotion;
        if (uci.length > 4) promotion = uci.substring(4);
        
        final moveMap = {'from': from, 'to': to};
        if (promotion != null) moveMap['promotion'] = promotion;
        
        if (!chessGame.move(moveMap)) {
           print('Failed to make move $uci');
           continue;
        }
        
        final nextFen = chessGame.fen;
        final eval = await _evaluateFen(nextFen, 10);
        chessGame.undo();
        
        final score = -eval.effectiveCp; 
        final qVal = _scoreToQ(score);
        final prob = maiaProbs[uci] ?? 0.0;
        
        final regret = math.max(0.0, maxQ - qVal);
        final term = math.pow(prob, _kBeta) * regret;
        sumWeightedRegret += term;
        
        results.add(EaseMove(
          uci: uci,
          prob: prob,
          score: score,
          qVal: qVal,
          regret: regret,
          moveEase: null,
        ));
      }
      
      // Populate moveEase for top 5 moves
      for (var i = 0; i < results.length && i < 5; i++) {
         final move = results[i];
         
         chessGame.load(fen);
         final from = move.uci.substring(0, 2);
         final to = move.uci.substring(2, 4);
         String? promotion;
         if (move.uci.length > 4) promotion = move.uci.substring(4);
         chessGame.move({'from': from, 'to': to, 'promotion': promotion});
         final nextFen = chessGame.fen;
         
         final nextEase = await _calculateFastEase(nextFen);
         
         results[i] = EaseMove(
            uci: move.uci,
            prob: move.prob,
            score: move.score,
            qVal: move.qVal,
            regret: move.regret,
            moveEase: nextEase,
         );
      }

      // 3. Ease Calculation
      final rawEase = 1.0 - math.pow(sumWeightedRegret / 2, _kAlpha);
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
  
  Future<double?> _calculateFastEase(String fen) async {
    try {
      if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return null;
      final maiaProbs = await MaiaFactory.instance!.evaluate(fen, 1900);
      
      final sortedMoves = maiaProbs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      final List<String> candidateUcis = [];
      double cumulativeProb = 0.0;

      for (final entry in sortedMoves) {
        final prob = entry.value;
        if (prob < 0.01) continue;
        candidateUcis.add(entry.key);
        cumulativeProb += prob;
        if (cumulativeProb > 0.90) break;
      }
      
      if (candidateUcis.isEmpty) return null;

      final rootEval = await _evaluateFen(fen, 1);
      final maxQ = _scoreToQ(rootEval.effectiveCp);
      
      double sumWeightedRegret = 0.0;
      final chessGame = chess.Chess.fromFEN(fen);
      
      for (final uci in candidateUcis) {
        final from = uci.substring(0, 2);
        final to = uci.substring(2, 4);
        String? promotion;
        if (uci.length > 4) promotion = uci.substring(4);
        
        if (!chessGame.move({'from': from, 'to': to, 'promotion': promotion})) continue;
        
        final eval = await _evaluateFen(chessGame.fen, 1);
        chessGame.undo();
        
        final score = -eval.effectiveCp;
        final qVal = _scoreToQ(score);
        final prob = maiaProbs[uci] ?? 0.0;
        
        final regret = math.max(0.0, maxQ - qVal);
        final term = math.pow(prob, _kBeta) * regret;
        sumWeightedRegret += term;
      }
      
      return 1.0 - math.pow(sumWeightedRegret / 2, _kAlpha);
    } catch (e) {
      print('Fast Ease Error: $e');
      return null;
    }
  }
  
  Future<EngineEvaluation> _evaluateFen(String fenToEval, int depth) async {
    if (_currentEvalCompleter != null && !_currentEvalCompleter!.isCompleted) {
       _currentEvalCompleter!.completeError('Cancelled');
    }
    
    _currentEvalCompleter = Completer<EngineEvaluation>();
    _currentEvalBestScore = null;
    _currentEvalWdl = null;
    _currentEvalBestMove = null;
    
    _engine!.sendCommand('stop');
    _engine!.sendCommand('position fen $fenToEval');
    _engine!.sendCommand('go depth $depth');
    
    return _currentEvalCompleter!.future;
  }

  Future<void> _ensureEngine() async {
    if (_engine != null) return;
    
    if (!StockfishConnectionFactory.isAvailable) {
      throw Exception('Engine not available on this platform');
    }
    
    _engine = await StockfishConnectionFactory.create();
    
    if (_engine == null) {
      throw Exception('Failed to create engine connection');
    }
    
    _engineSubscription = _engine!.stdout.listen((line) {
      _handleEngineOutput(line);
    });

    _engine!.sendCommand('uci');
    _engine!.sendCommand('isready');
  }
  
  void _handleEngineOutput(String line) {
    line = line.trim();
    if (_currentEvalCompleter == null || _currentEvalCompleter!.isCompleted) return;

    if (line.startsWith('info') && (line.contains('score') || line.contains('wdl'))) {
      if (line.contains('score')) {
        final score = _parseScore(line);
        if (score != null) _currentEvalBestScore = score;
      }
      
      if (line.contains('wdl')) {
        final wdl = _parseWdl(line);
        if (wdl != null) _currentEvalWdl = wdl;
      }
    }
    
    if (line.startsWith('bestmove')) {
       final parts = line.split(' ');
       if (parts.length > 1) _currentEvalBestMove = parts[1];
       
       _currentEvalCompleter?.complete(
         EngineEvaluation(
           scoreCp: _currentEvalBestScore, 
           pv: _currentEvalBestMove != null ? [_currentEvalBestMove!] : [],
           wdl: _currentEvalWdl,
         )
       );
       _currentEvalCompleter = null;
    }
  }
  
  List<int>? _parseWdl(String line) {
    try {
      final parts = line.split(' ');
      final wdlIdx = parts.indexOf('wdl');
      if (wdlIdx == -1 || wdlIdx + 3 >= parts.length) return null;
      
      final wins = int.tryParse(parts[wdlIdx + 1]);
      final draws = int.tryParse(parts[wdlIdx + 2]);
      final losses = int.tryParse(parts[wdlIdx + 3]);
      
      if (wins != null && draws != null && losses != null) {
        return [wins, draws, losses];
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  int? _parseScore(String line) {
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
    if (cp.abs() > 9000) return cp > 0 ? 1.0 : -1.0;
    final winProb = 1.0 / (1.0 + math.exp(-0.004 * cp));
    return 2.0 * winProb - 1.0;
  }

  void dispose() {
    _engineSubscription?.cancel();
    _engine?.dispose();
    _engine = null;
    _currentEvalCompleter = null;
  }
}
