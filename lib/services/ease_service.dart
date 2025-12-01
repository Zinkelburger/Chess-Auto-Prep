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

  // Notifier for status updates
  final ValueNotifier<String> status = ValueNotifier('Idle');
  final ValueNotifier<EaseResult?> currentResult = ValueNotifier(null);
  
  EngineConnection? _engine;
  StreamSubscription? _engineSubscription;
  bool _isAnalyzing = false;
  
  // State for the current evaluation request
  Completer<EngineEvalResult>? _currentEvalCompleter;
  int? _currentEvalBestScore;
  List<int>? _currentEvalWdl;
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
      // Use 1900 Elo model
      final maiaProbs = await MaiaService().evaluate(fen, 1900);
      
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
      final safetyFactor = 1.0; // Feature disabled: _calculateSafetyFactor(rootEval);

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
          // Calculate recursive ease for this move?
          // The user asked for "ease score for the moves we're showing"
          // Ease is a position metric. So we want the ease of the position *after* this move.
          // But since we are looking at opponent moves, "lower is better for us" implies
          // we want to know if the resulting position is easy for THEM or difficult for THEM.
          
          // Actually, Ease is "probability weighted regret". 
          // A position is "easy" if good moves are obvious (high prob).
          
          // If we want to show an ease score for a move, it likely means:
          // "If this move is played, what is the Ease of the resulting position?"
          
          // To calculate that, we would need to run the full Ease calculation (Maia + Stockfish)
          // for the resulting position of *every* candidate move.
          // That would be O(N^2) and very slow (running Maia N times).
          
          // Alternatively, maybe "move ease" just means the contribution of this move to the current position's ease?
          // "raw_ease = 1 - sum(regret * prob^beta)". 
          // The term `regret * prob^beta` is the "difficulty contribution" of this move.
          
          // Re-reading: "ease score for the moves we're showing... which are from the opponents perspective, notably, so lower is better in this case for us"
          // This implies we want to know the Ease of the position *after* the opponent makes that move.
          // If the resulting position has Low Ease (difficult for us), that's bad for us?
          // "moves... from the opponents perspective".
          // If it's the opponent's turn, we are analyzing their moves.
          // The Ease of the *current* position tells us how easy it is for the opponent to find good moves.
          // Low Ease = Opponent likely to blunder. High Ease = Opponent has obvious good moves.
          
          // If the user wants an Ease score *per move*, they probably mean:
          // "If they play Move A, I will face Position A. What is the Ease of Position A (for me)?"
          
          // Calculating full Ease for every candidate is too heavy.
          // BUT, we already did a shallow search (depth 10) for each candidate.
          // We have the `score` (eval) of the resulting position.
          // We DO NOT have the Maia probabilities for the next position (requires N Maia inferences).
          
          // Given constraints, maybe we can't provide a full "Ease" score for the next position without significant lag.
          // Is there a misunderstanding? 
          // "ease score for the moves we're showing"
          
          // Let's assume we just want to display the "Difficulty Contribution" of this move to the current Ease score?
          // No, "lower is better for us" implies it's about the resulting position.
          // If the opponent plays a move that leads to a position that is "Easy" for us (High Ease), that is good.
          // User said "lower is better... for us". This is confusing.
          
          // Let's assume the user wants the "Difficulty" (1 - Ease) of the *current* move choice?
          // Or the "Regret" which we already show?
          
          // Let's implement a simplified "Move Ease" which is just `1 - regret`.
          // If regret is high (bad move), "Move Ease" is low.
          // This doesn't seem right.
          
          // Let's go with the interpretation: "Ease of the resulting position".
          // Since we can't run Maia N times, we might have to skip this or approximate.
          // BUT, we *could* run it if N is small (top 5 moves).
          // Maia inference takes ~50-100ms on CPU. 5 moves = 500ms. Feasible?
          // Let's try to implement it for the top few moves only?
          
          // Actually, let's look at the `moveEase` field I added.
          // I will calculate `term = prob^BETA * regret`.
          // This is the "Un-ease" contribution.
          // Maybe display that?
          
          // Wait, if the user says "lower is better", maybe they mean the Ease of the position *after* the opponent moves.
          // If the opponent plays a move, it becomes OUR turn.
          // We want a position that is High Ease for US (easy to find good moves).
          // So Higher is Better.
          // User said "lower is better".
          // Maybe they mean "Ease of opponent finding this move"?
          
          // Let's implement the "Ease of resulting position" but purely based on Stockfish static eval complexity? No.
          
          // Let's implement the full recursive Ease calculation for the top 3 candidates.
          // It will add ~1-2 seconds delay.
          
          // UPDATE: I will just calculate the recursive ease for the moves.
          // I need to call `calculateEase` recursively? No, that updates the UI state.
          // I need a helper `_calculateRawEaseForFen(fen)`.
          
          // Refactoring `calculateEase` to extract the logic into a helper is best.
          
          moveEase: null, // Will be populated later
        ));
      }
      
      // Populate moveEase for top 5 moves
      // We need to calculate the Ease of the position *after* the move.
      // After move UCI, it is the OTHER side's turn.
      // The Ease of that position represents how easy it is for the OTHER side (us) to play.
      // High Ease = We have obvious good moves.
      // Low Ease = We have to find tricky moves.
      
      // User said: "lower is better in this case for us".
      // If "lower is better", they want Low Ease for US? That means we want a difficult position?
      // Maybe they mean "Evaluated from Opponent's perspective".
      // If opponent plays Move X, they face Position Y (Our turn).
      // Ease of Position Y is "How easy for US".
      // If user implies "lower is better", maybe they refer to the *Opponent's* Ease?
      // No, we are analyzing the current position (Opponent to move).
      // The "Ease" displayed at the top is "Ease for Opponent".
      
      // Let's just calculate the Ease of the *next* position (for us) and let the user interpret.
      // I will add a helper `_calculateEaseForFen` that returns just the double.
      
      // Limiting to top 5 to save time
      for (var i = 0; i < results.length && i < 5; i++) {
         final move = results[i];
         
         // Apply move to get next FEN
         chessGame.load(fen);
         final from = move.uci.substring(0, 2);
         final to = move.uci.substring(2, 4);
         String? promotion;
         if (move.uci.length > 4) promotion = move.uci.substring(4);
         chessGame.move({'from': from, 'to': to, 'promotion': promotion});
         final nextFen = chessGame.fen;
         
         // Calculate Ease for next position (Our turn)
         final nextEase = await _calculateFastEase(nextFen);
         
         // Update result with new moveEase
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
  
  Future<double?> _calculateFastEase(String fen) async {
    try {
      // 1. Maia
      final maiaProbs = await MaiaService().evaluate(fen, 1900);
      
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

      // 2. Eval
      // Root
      final rootEval = await _evaluateFen(fen, 1); // Very fast depth 1
      final maxQ = _scoreToQ(rootEval.score);
      
      double sumWeightedRegret = 0.0;
      final chessGame = chess.Chess.fromFEN(fen);
      
      for (final uci in candidateUcis) {
        final from = uci.substring(0, 2);
        final to = uci.substring(2, 4);
        String? promotion;
        if (uci.length > 4) promotion = uci.substring(4);
        
        if (!chessGame.move({'from': from, 'to': to, 'promotion': promotion})) continue;
        
        // Very fast candidate eval
        final eval = await _evaluateFen(chessGame.fen, 1);
        chessGame.undo();
        
        final score = -eval.score;
        final qVal = _scoreToQ(score);
        final prob = maiaProbs[uci] ?? 0.0;
        
        final regret = math.max(0.0, maxQ - qVal);
        final term = math.pow(prob, BETA) * regret;
        sumWeightedRegret += term;
      }
      
      return 1.0 - math.pow(sumWeightedRegret / 2, ALPHA);
    } catch (e) {
      print('Fast Ease Error: $e');
      return null;
    }
  }
  
  Future<EngineEvalResult> _evaluateFen(String fenToEval, int depth) async {
    if (_currentEvalCompleter != null && !_currentEvalCompleter!.isCompleted) {
       _currentEvalCompleter!.completeError('Cancelled');
    }
    
    _currentEvalCompleter = Completer<EngineEvalResult>();
    _currentEvalBestScore = null;
    _currentEvalWdl = null;
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

    if (line.startsWith('info') && (line.contains('score') || line.contains('wdl'))) {
      // Parse score if present
      if (line.contains('score')) {
        final score = _parseScore(line, _currentEvalFen ?? '');
        if (score != null) _currentEvalBestScore = score;
      }
      
      // Parse WDL if present
      if (line.contains('wdl')) {
        final wdl = _parseWdl(line);
        if (wdl != null) _currentEvalWdl = wdl;
      }
    }
    
    if (line.startsWith('bestmove')) {
       final parts = line.split(' ');
       String? bestPv;
       if (parts.length > 1) bestPv = parts[1];
       
       _currentEvalCompleter?.complete(
         EngineEvalResult(
           score: _currentEvalBestScore ?? 0, 
           bestMove: bestPv,
           wdl: _currentEvalWdl
         )
       );
       _currentEvalCompleter = null;
    }
  }
  
  // Helpers
  List<int>? _parseWdl(String line) {
    try {
      // info ... wdl 123 456 789 ...
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
  
  double _calculateSafetyFactor(EngineEvalResult eval) {
    // 1. Use WDL if available (Wins + Draws / Total)
    // WDL from Stockfish is usually [Wins, Draws, Losses] per 1000 games
    if (eval.wdl != null && eval.wdl!.length == 3) {
      final wins = eval.wdl![0];
      final draws = eval.wdl![1];
      final losses = eval.wdl![2];
      final total = wins + draws + losses;
      
      if (total > 0) {
        final nonLosingProb = (wins + draws) / total;
        // Scale: pow(prob, 0.25) to dampen extreme values, similar to original script
        return math.pow(nonLosingProb, 0.25).toDouble();
      }
    }

    // 2. Fallback to CP-based estimation
    final cp = eval.score;
    if (cp >= -50) return 1.0;
    // Linear decay from -50 to -1050
    // -50 -> 1.0
    // -1050 -> 0.0
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
  final List<int>? wdl;
  
  EngineEvalResult({
    required this.score, 
    this.bestMove,
    this.wdl
  });
}

extension ListAppend<T> on List<T> {
  void append(T item) => add(item);
}
