/// Controller that runs Stockfish through every mainline position of a game
/// and collects per-move evaluations for charting and move classification.
///
/// Uses the [StockfishPool] to evaluate multiple positions in parallel,
/// significantly speeding up full-game analysis.
///
/// Uses Lichess-style winning-chance model for move classification:
/// - Blunder (??): winning chance swing >= 0.30
/// - Mistake (?):  winning chance swing >= 0.20
/// - Inaccuracy (?!): winning chance swing >= 0.10
///
/// Persists analysis results as standard `[%eval]` comments in PGN, matching
/// the Lichess export format. On subsequent loads, analysis is restored from
/// these annotations without re-running the engine.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../utils/chess_utils.dart' show uciPvToSan, uciToSan, toStandardUci;
import '../utils/ease_utils.dart' show winningChanceFromCp;
import '../utils/eval_constants.dart';
import '../utils/pgn_comment_utils.dart';
import 'engine/stockfish_pool.dart';
import 'maia_factory.dart';

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

/// Eval at a single ply (after the move is played).
class MoveEval {
  final int ply; // 1-based: 1 = after White's first move
  final String san;
  final String fenBefore;
  final String fenAfter;
  final int? scoreCp; // White-normalized centipawns
  final int? scoreMate; // White-normalized mate-in-N
  final double winningChance; // White's winning chance in [-1, 1]
  final MoveClassification classification;
  final double? maiaProb; // MAIA's predicted probability of this move (0-1)
  final String? maiaTopMove; // Most likely move according to MAIA (SAN)
  final double? maiaTopProb; // Probability of the most likely MAIA move
  final List<String> bestLine; // Engine's preferred continuation (SAN)
  final int? depth; // Analysis depth

  const MoveEval({
    required this.ply,
    required this.san,
    required this.fenBefore,
    required this.fenAfter,
    this.scoreCp,
    this.scoreMate,
    required this.winningChance,
    this.classification = MoveClassification.normal,
    this.maiaProb,
    this.maiaTopMove,
    this.maiaTopProb,
    this.bestLine = const [],
    this.depth,
  });

  bool get isWhiteMove => ply % 2 == 1;

  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: scoreCp, scoreMate: scoreMate);

  /// Format as a Lichess-compatible `[%eval]` comment value, with optional
  /// depth suffix (e.g. `1.23,18` or `#3,20`).
  String toEvalComment() {
    String base;
    if (scoreMate != null) {
      base = '#$scoreMate';
    } else if (scoreCp != null) {
      final v = scoreCp! / 100.0;
      base = v.toStringAsFixed(2);
    } else {
      base = '0.00';
    }
    if (depth != null) return '$base,$depth';
    return base;
  }
}

enum MoveClassification { normal, interesting, inaccuracy, mistake, blunder }

// ---------------------------------------------------------------------------
// Winning-chance model (Lichess logistic)
// ---------------------------------------------------------------------------

/// Lichess-style centipawn-to-winning-chance conversion.
///
/// Maps mate scores to pseudo-CP, then delegates to the shared
/// [winningChanceFromCp] curve (the same `kWinProbK` logistic used by the
/// ease/expectimax pipeline). See [winningChanceFromCp] for why the input is
/// clamped to ±1000 cp here rather than saturated at mate scores.
double cpToWinningChance(int? cp, int? mate) =>
    winningChanceFromCp(effectiveCpFromScores(scoreCp: cp, scoreMate: mate));

/// Classify a move based on the change in winning chances.
MoveClassification classifyMove(double delta) {
  if (delta >= 0.30) return MoveClassification.blunder;
  if (delta >= 0.20) return MoveClassification.mistake;
  if (delta >= 0.10) return MoveClassification.inaccuracy;
  return MoveClassification.normal;
}

// ---------------------------------------------------------------------------
// Isolate-safe top-level parser for cached evals (used by compute())
// ---------------------------------------------------------------------------

({List<MoveEval> evals, double startWinChance, int totalMoves})?
_parseCachedEvals(String pgnText) {
  final parsed = PgnGame.parsePgn(pgnText);
  final mainline = parsed.moves.mainline().toList();
  if (mainline.isEmpty) return null;

  final setupFlag = parsed.headers['SetUp'] ?? parsed.headers['Setup'] ?? '';
  final fenHeader = parsed.headers['FEN'] ?? '';
  Position pos;
  if (setupFlag == '1' && fenHeader.isNotEmpty) {
    pos = Chess.fromSetup(Setup.parseFen(fenHeader));
  } else {
    pos = Chess.initial;
  }

  final results = <MoveEval>[];
  int missingCount = 0;

  for (int i = 0; i < mainline.length; i++) {
    final moveData = mainline[i];
    final fenBefore = pos.fen;
    final move = pos.parseSan(moveData.san);
    if (move == null) break;
    pos = pos.play(move);
    final fenAfter = pos.fen;

    ({int? cp, int? mate, int? depth})? evalData;
    double? maiaProb;
    List<String> bestLine = const [];
    ({String move, double prob})? maiaTop;
    if (moveData.comments != null) {
      for (final c in moveData.comments!) {
        evalData ??= parseEvalComment(c);
        maiaProb ??= parseMaiaComment(c);
        maiaTop ??= parseMaiaTopComment(c);
        if (bestLine.isEmpty) {
          final pv = parsePvComment(c);
          if (pv.isNotEmpty) bestLine = pv;
        }
      }
    }

    if (evalData == null) {
      missingCount++;
      if (missingCount > 2) return null;
      continue;
    }

    final winChance = cpToWinningChance(evalData.cp, evalData.mate);
    results.add(
      MoveEval(
        ply: i + 1,
        san: moveData.san,
        fenBefore: fenBefore,
        fenAfter: fenAfter,
        scoreCp: evalData.cp,
        scoreMate: evalData.mate,
        winningChance: winChance,
        maiaProb: maiaProb,
        maiaTopMove: maiaTop?.move,
        maiaTopProb: maiaTop?.prob,
        bestLine: bestLine,
        depth: evalData.depth,
      ),
    );
  }

  if (results.length < mainline.length - 2) return null;

  final startWinChance = cpToWinningChance(0, null);
  double prevWinChance = startWinChance;

  final classified = <MoveEval>[];
  for (final e in results) {
    final delta = e.isWhiteMove
        ? (prevWinChance - e.winningChance)
        : (e.winningChance - prevWinChance);
    var classification = classifyMove(delta.clamp(0.0, 1.0));

    if (classification == MoveClassification.normal &&
        e.maiaProb != null &&
        e.maiaProb! < 0.05) {
      classification = MoveClassification.interesting;
    }

    classified.add(
      MoveEval(
        ply: e.ply,
        san: e.san,
        fenBefore: e.fenBefore,
        fenAfter: e.fenAfter,
        scoreCp: e.scoreCp,
        scoreMate: e.scoreMate,
        winningChance: e.winningChance,
        maiaProb: e.maiaProb,
        maiaTopMove: e.maiaTopMove,
        maiaTopProb: e.maiaTopProb,
        bestLine: e.bestLine,
        depth: e.depth,
        classification: classification,
      ),
    );
    prevWinChance = e.winningChance;
  }

  return (
    evals: classified,
    startWinChance: startWinChance,
    totalMoves: mainline.length,
  );
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class GameAnalysisController extends ChangeNotifier {
  List<MoveEval> _evals = [];
  List<MoveEval> get evals => _evals;

  double _startWinChance = 0.0;
  double get startWinChance => _startWinChance;

  bool _isAnalyzing = false;
  bool get isAnalyzing => _isAnalyzing;

  int _totalMoves = 0;
  int get totalMoves => _totalMoves;

  int _analyzedMoves = 0;
  int get analyzedMoves => _analyzedMoves;

  int _depth = 18;
  int get depth => _depth;
  set depth(int value) {
    _depth = value.clamp(8, 30);
    notifyListeners();
  }

  bool _isCancelled = false;

  // ── Loading cached analysis from PGN ────────────────────────────────────

  Future<bool> tryLoadFromPgn(String pgnText) async {
    _evals = [];

    try {
      final result = await compute(_parseCachedEvals, pgnText);
      if (result == null) return false;

      _evals = result.evals;
      _startWinChance = result.startWinChance;
      _totalMoves = result.totalMoves;
      _analyzedMoves = result.evals.length;
      notifyListeners();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[GameAnalysis] Failed to load cached: $e');
      return false;
    }
  }

  void clearEvals() {
    _evals = [];
    _totalMoves = 0;
    _analyzedMoves = 0;
    _startWinChance = 0.0;
    notifyListeners();
  }

  // ── Running engine analysis (parallel via StockfishPool) ────────────────

  /// Analyze a full game using the StockfishPool for parallel evaluation.
  /// Positions are dispatched in batches matching the pool's worker count.
  Future<void> analyzeGame(
    String pgnText, {
    int? analysisDepth,
    ValueChanged<String>? onAnnotatedMovetext,
    VoidCallback? onComplete,
  }) async {
    if (_isAnalyzing) cancel();

    _evals = [];
    _analyzedMoves = 0;
    _isAnalyzing = true;
    _isCancelled = false;
    notifyListeners();

    final useDepth = analysisDepth ?? _depth;
    final pool = StockfishPool.instance;

    try {
      final parsed = PgnGame.parsePgn(pgnText);
      final mainline = parsed.moves.mainline().toList();
      _totalMoves = mainline.length;
      notifyListeners();

      if (mainline.isEmpty) {
        _isAnalyzing = false;
        notifyListeners();
        return;
      }

      await pool.ensureWorkers();
      if (_isCancelled) return;

      final workerCount = pool.workerCount;
      if (workerCount == 0) {
        _isAnalyzing = false;
        notifyListeners();
        return;
      }

      final setupFlag =
          parsed.headers['SetUp'] ?? parsed.headers['Setup'] ?? '';
      final fenHeader = parsed.headers['FEN'] ?? '';
      Position pos;
      if (setupFlag == '1' && fenHeader.isNotEmpty) {
        pos = Chess.fromSetup(Setup.parseFen(fenHeader));
      } else {
        pos = Chess.initial;
      }
      final positions =
          <
            ({
              String fenBefore,
              String fenAfter,
              bool isWhiteToMove,
              PgnNodeData moveData,
              String moveUci,
            })
          >[];
      for (final moveData in mainline) {
        final fenBefore = pos.fen;
        final move = pos.parseSan(moveData.san);
        if (move == null) break;
        // Use standard UCI (king→destination for castling) so Maia policy
        // lookups match the vocabulary convention.
        final uci = move is NormalMove
            ? toStandardUci(pos, move.from, move.to)
            : move.uci;
        pos = pos.play(move);
        positions.add((
          fenBefore: fenBefore,
          fenAfter: pos.fen,
          isWhiteToMove: pos.turn == Side.white,
          moveData: moveData,
          moveUci: uci,
        ));
      }

      final startFen = (setupFlag == '1' && fenHeader.isNotEmpty)
          ? fenHeader
          : 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      final startResult = await pool.evaluateFen(startFen, useDepth);
      if (_isCancelled) return;
      _startWinChance = cpToWinningChance(
        startResult.scoreCp,
        startResult.scoreMate,
      );

      // Initialize MAIA
      final maia = MaiaFactory.instance;
      bool maiaReady = false;
      if (maia != null) {
        try {
          await maia.initialize();
          maiaReady = true;
        } catch (e) {
          if (kDebugMode) debugPrint('[GameAnalysis] MAIA init failed: $e');
        }
      }

      final whiteElo = int.tryParse(parsed.headers['WhiteElo'] ?? '') ?? 2200;
      final blackElo = int.tryParse(parsed.headers['BlackElo'] ?? '') ?? 2200;

      double prevWinChance = _startWinChance;
      // Track the PV from the *before* position so we can show "what should
      // have been played" rather than the continuation after a blunder.
      List<String> prevBeforePv = startResult.pv;
      String prevBeforeFen = startFen;

      // Process in parallel batches — classify incrementally
      final batchSize = workerCount;
      for (
        int batchStart = 0;
        batchStart < positions.length;
        batchStart += batchSize
      ) {
        if (_isCancelled) break;

        final batchEnd = (batchStart + batchSize).clamp(0, positions.length);
        final batch = positions.sublist(batchStart, batchEnd);

        // Fire off Stockfish evals concurrently
        final futures = <Future<EvalResult>>[];
        for (final p in batch) {
          futures.add(pool.evaluateFen(p.fenAfter, useDepth));
        }

        final results = await Future.wait(futures);
        if (_isCancelled) break;

        for (int j = 0; j < results.length; j++) {
          if (_isCancelled) break;
          final p = batch[j];
          final result = results[j];
          final globalIdx = batchStart + j;
          final ply = globalIdx + 1;

          final whiteNormCp = p.isWhiteToMove
              ? result.scoreCp
              : _negateCp(result.scoreCp);
          final whiteNormMate = p.isWhiteToMove
              ? result.scoreMate
              : _negateMate(result.scoreMate);
          final winChance = cpToWinningChance(whiteNormCp, whiteNormMate);

          // Classify immediately
          final isWhiteMove = ply % 2 == 1;
          final delta = isWhiteMove
              ? (prevWinChance - winChance)
              : (winChance - prevWinChance);
          var classification = classifyMove(delta.clamp(0.0, 1.0));

          // Run MAIA before choosing the best line, so "interesting" moves
          // (reclassified from normal) also get the pre-move engine line.
          double? maiaProb;
          String? maiaTopMove;
          double? maiaTopProb;
          if (maiaReady) {
            try {
              final elo = isWhiteMove ? whiteElo : blackElo;
              final maiaResult = await maia!.evaluate(p.fenBefore, elo);
              maiaProb = maiaResult.policy[p.moveUci] ?? 0.0;
              _injectMaiaComment(p.moveData, maiaProb);

              // Find the most likely MAIA move
              if (maiaResult.policy.isNotEmpty) {
                String topUci = maiaResult.policy.keys.first;
                double topP = maiaResult.policy.values.first;
                for (final entry in maiaResult.policy.entries) {
                  if (entry.value > topP) {
                    topUci = entry.key;
                    topP = entry.value;
                  }
                }
                maiaTopProb = topP;
                maiaTopMove = _uciMoveToSan(p.fenBefore, topUci);
              }
            } catch (e) {
              if (kDebugMode) debugPrint('[GameAnalysis] MAIA eval failed: $e');
            }
          }

          if (classification == MoveClassification.normal &&
              maiaProb != null &&
              maiaProb < 0.05) {
            classification = MoveClassification.interesting;
          }

          // For non-normal moves (including interesting), show the engine's
          // preferred line from the position *before* the move. For normal
          // moves, show the continuation from after the move.
          final List<String> bestLine;
          if (classification != MoveClassification.normal) {
            bestLine = _uciPvToSan(prevBeforeFen, prevBeforePv);
          } else {
            bestLine = _uciPvToSan(p.fenAfter, result.pv);
          }

          final eval = MoveEval(
            ply: ply,
            san: p.moveData.san,
            fenBefore: p.fenBefore,
            fenAfter: p.fenAfter,
            scoreCp: whiteNormCp,
            scoreMate: whiteNormMate,
            winningChance: winChance,
            bestLine: bestLine,
            classification: classification,
            maiaProb: maiaProb,
            maiaTopMove: maiaTopMove,
            maiaTopProb: maiaTopProb,
            depth: useDepth,
          );
          _evals.add(eval);
          _injectEvalComment(p.moveData, eval);
          prevWinChance = winChance;
          prevBeforePv = result.pv;
          prevBeforeFen = p.fenAfter;
        }

        _analyzedMoves = _evals.length;
        notifyListeners();
      }

      if (!_isCancelled && onAnnotatedMovetext != null) {
        final annotated = _rebuildMovetext(mainline, parsed.headers['Result']);
        onAnnotatedMovetext(annotated);
      }
      if (!_isCancelled) onComplete?.call();
    } catch (e, st) {
      debugPrint('[GameAnalysis] Error: $e\n$st');
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }

  void _injectEvalComment(PgnNodeData moveData, MoveEval eval) {
    final evalValue = eval.toEvalComment();
    if (moveData.comments != null && moveData.comments!.isNotEmpty) {
      var comment = moveData.comments!.first;
      comment = setEvalInComment(comment, evalValue);
      if (eval.bestLine.isNotEmpty) {
        comment = setPvInComment(comment, eval.bestLine);
      }
      if (eval.maiaTopMove != null && eval.maiaTopProb != null) {
        comment = setMaiaTopInComment(
          comment,
          eval.maiaTopMove!,
          eval.maiaTopProb!,
        );
      }
      moveData.comments![0] = comment;
    } else {
      var comment = '[%eval $evalValue]';
      if (eval.bestLine.isNotEmpty) {
        comment = '$comment [%pv ${eval.bestLine.join(',')}]';
      }
      if (eval.maiaTopMove != null && eval.maiaTopProb != null) {
        comment = setMaiaTopInComment(
          comment,
          eval.maiaTopMove!,
          eval.maiaTopProb!,
        );
      }
      moveData.comments = [comment];
    }
  }

  void _injectMaiaComment(PgnNodeData moveData, double prob) {
    if (moveData.comments != null && moveData.comments!.isNotEmpty) {
      moveData.comments![0] = setMaiaInComment(moveData.comments!.first, prob);
    } else {
      moveData.comments = ['[%maia ${prob.toStringAsFixed(3)}]'];
    }
  }

  String _rebuildMovetext(List<PgnNodeData> mainline, String? result) =>
      buildMovetext(mainline, result: result);

  void cancel() {
    _isCancelled = true;
    StockfishPool.instance.stopAll();
  }

  List<String> _uciPvToSan(String fen, List<String> uciMoves) =>
      uciPvToSan(fen, uciMoves);

  String? _uciMoveToSan(String fen, String uci) => uciToSan(fen, uci);

  int? _negateCp(int? cp) => cp != null ? -cp : null;
  int? _negateMate(int? mate) => mate != null ? -mate : null;

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}
