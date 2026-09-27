/// Controller that runs Stockfish through every mainline position of a game
/// and collects per-move evaluations for charting and move classification.
///
/// Uses the [StockfishPool] to evaluate multiple positions in parallel,
/// significantly speeding up full-game analysis. Scores are classified with
/// the winning-chance model in `move_eval.dart` and persisted as standard
/// `[%eval]` comments through `game_eval_annotations.dart`; on later loads
/// the series is restored from those annotations without the engine.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../features/documents/repositories/viewer_analysis_port.dart';
import '../constants/chess_constants.dart';
import '../features/settings/models/bulk_analysis_configuration.dart';
import '../chess_core/pgn/pgn_dummy_mainline.dart';
import '../utils/chess_utils.dart'
    show uciPvToSan, uciToSan, toStandardUci, isNullMoveSan;
import '../utils/fen_utils.dart';
import '../utils/safe_change_notifier.dart';
import 'engine/engine_lifecycle.dart';
import 'engine/eval_worker.dart';
import 'engine/stockfish_pool.dart';
import 'eval_cache.dart';
import 'package:chess_auto_prep/chess_core/analysis/game_eval_annotations.dart';
import 'maia/maia_factory.dart';
import 'package:chess_auto_prep/chess_core/analysis/move_eval.dart';

/// Elo assumed for a player whose header carries none, for Maia.
const int _kDefaultElo = 2200;

class GameAnalysisController extends ChangeNotifier
    with SafeChangeNotifier
    implements ViewerAnalysisPort {
  GameAnalysisController({
    required this.pool,
    required this.lifecycle,
    Future<CachedGameAnalysis?> Function(String pgnText)? cachedAnalysisLoader,
    int Function()? bulkDepth,
  }) : _bulkDepth = bulkDepth ?? (() => BulkAnalysisConfiguration.defaultDepth),
       _cachedAnalysisLoader =
           cachedAnalysisLoader ??
           ((pgnText) => compute(parseCachedEvals, pgnText));

  final StockfishPool pool;
  final EngineLifecycle lifecycle;
  final int Function() _bulkDepth;

  final Future<CachedGameAnalysis?> Function(String pgnText)
  _cachedAnalysisLoader;

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

  /// Depth of the running (or most recent) pass. Falls back to the shared
  /// Stockfish "Depth" setting — full-game analysis has no depth knob of its
  /// own; it follows the one in the Stockfish settings dialog.
  int? _activeDepth;
  int get depth => _activeDepth ?? _bulkDepth();

  bool _isCancelled = false;

  /// Bumped by every load, clear, cancel and analysis start, so work begun
  /// for one game ([fillMissingBestLines]) cannot land on the next.
  int _generation = 0;

  void _resetSeries() {
    _evals = [];
    _totalMoves = 0;
    _analyzedMoves = 0;
    _startWinChance = 0;
  }

  // ── Loading cached analysis from PGN ────────────────────────────────────

  @override
  Future<bool> tryLoadFromPgn(String pgnText) async {
    final generation = ++_generation;
    _resetSeries();

    try {
      final result = await _cachedAnalysisLoader(pgnText);
      if (isDisposed || generation != _generation) return false;
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

  /// The classified moves of the loaded series that have no line behind
  /// them. See [MoveEval.needsBestLine].
  List<MoveEval> get movesMissingBestLine => [
    for (final e in _evals)
      if (e.needsBestLine) e,
  ];

  /// Search for the lines the stored series is missing, so a review-pass
  /// graph always opens with something to click on its mistakes.
  ///
  /// The series a review pass stores scores every ply, but the line behind a
  /// score was not always kept (passes from before lines were stored; scores
  /// served from the shared eval cache, which holds no lines). The tab's
  /// cards and the movetext's inline marks both go quiet on such a move.
  /// This searches just those positions — a handful, at the depth the series
  /// was scored at — puts the lines on the loaded evals, and hands the
  /// re-annotated movetext to [onAnnotatedMovetext] so it is stored and never
  /// searched again.
  ///
  /// Silent when there is nothing to fill, while a full analysis is running,
  /// while repertoire generation holds the engine, or when no engine can be
  /// started; a load of a different game in the meantime discards the result.
  @override
  Future<void> fillMissingBestLines(
    String pgnText, {
    ValueChanged<String>? onAnnotatedMovetext,
  }) async {
    if (_isAnalyzing) return;
    final missing = movesMissingBestLine;
    if (missing.isEmpty) return;
    if (lifecycle.state == EngineState.generating) return;
    final generation = _generation;

    // The depth the graph was drawn at, so the lines agree with the scores
    // beside them; the engine setting when the series does not say.
    var depth = _bulkDepth();
    for (final e in missing) {
      final d = e.depth;
      if (d != null && d < depth) depth = d;
    }

    final List<EvalResult> results;
    try {
      await pool.ensureWorkers();
      if (pool.workerCount == 0) return;
      results = await pool.evaluateMany([
        for (final e in missing) e.fenBefore,
      ], depth);
    } catch (e) {
      if (kDebugMode) debugPrint('[GameAnalysis] Line fill failed: $e');
      return;
    }
    if (generation != _generation || _isAnalyzing) return;

    final linesByPly = <int, List<String>>{};
    for (var i = 0; i < missing.length; i++) {
      final line = uciPvToSan(missing[i].fenBefore, results[i].pv);
      if (line.isNotEmpty) linesByPly[missing[i].ply] = line;
    }
    if (linesByPly.isEmpty) return;

    _evals = [
      for (final e in _evals)
        switch (linesByPly[e.ply]) {
          final line? => e.copyWith(bestLine: line),
          null => e,
        },
    ];
    notifyListeners();

    if (onAnnotatedMovetext == null) return;
    final annotated = injectBestLines(pgnText, linesByPly);
    if (annotated != null) onAnnotatedMovetext(annotated);
  }

  @override
  void clearEvals() {
    _generation++;
    _isAnalyzing = false;
    _resetSeries();
    _activeDepth = null;
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

    final generation = ++_generation;
    _resetSeries();
    _isAnalyzing = true;
    _isCancelled = false;
    notifyListeners();

    final depth = analysisDepth ?? _bulkDepth();
    _activeDepth = depth;
    bool runIsCurrent() =>
        !isDisposed && !_isCancelled && generation == _generation;

    try {
      final parsed = parsePgnGame(pgnText);
      promoteNullMoveDummyMainline(parsed.moves);
      final mainline = parsed.moves.mainline().toList();
      _totalMoves = mainline.where((move) => !isNullMoveSan(move.san)).length;
      notifyListeners();
      if (mainline.isEmpty) return;

      await pool.ensureWorkers();
      if (!runIsCurrent()) return;
      final workerCount = pool.workerCount;
      if (workerCount == 0) return;

      final startFen = setupFenOf(parsed.headers) ?? kStandardStartFen;
      final replay = replayMainline(
        gameStartPosition(parsed.headers),
        mainline,
      );
      final plies = replay.plies;
      // A game ending in mate or stalemate has no position left to search
      // after its final move — asking the engine yields a sign-ambiguous
      // mate-0 score, so the result is read off the board instead.
      final endsInCheckmate = plies.isNotEmpty && replay.end.isCheckmate;
      final endsInStalemate =
          plies.isNotEmpty && !endsInCheckmate && replay.end.isStalemate;
      bool isTerminal(int index) =>
          index == plies.length - 1 && (endsInCheckmate || endsInStalemate);

      final startResult = await pool.evaluateFen(startFen, depth);
      if (!runIsCurrent()) return;
      _shareEval(
        startFen,
        startResult,
        sideToMoveIsWhite: isWhiteToMove(startFen),
        depth: depth,
      );
      // The anchor the FIRST move's swing is measured against — and it has to
      // be the same one every reader will use. This pass persists movetext
      // only (`onAnnotatedMovetext`), so nothing carries the engine's score
      // for the starting position onto disk: `parseCachedEvals` and the
      // movetext's own `_buildEvalNotes` both restart the chain at an even
      // game. Anchoring the live pass on `startResult` instead made move 1
      // classify one way while the run was on screen and another way the
      // next time the game was opened — 1.g4 marked as a mistake, then
      // unmarked on reload. A mark the stored game cannot reproduce is worse
      // than a slightly conservative anchor, so the writer uses the reader's.
      // `startResult` is still wanted below, for move 1's "what to play
      // instead" line.
      _startWinChance = initialWinChance();

      final maia = await _initializedMaia();
      if (!runIsCurrent()) return;
      final whiteElo = _eloOf(parsed.headers['WhiteElo']);
      final blackElo = _eloOf(parsed.headers['BlackElo']);

      // The chain carries the previous ply's winning chance and the engine
      // line from the position *before* the current move, so a mistake can
      // show "what should have been played" rather than the continuation
      // after it.
      var prevWinChance = _startWinChance;
      var prevBeforePv = startResult.pv;
      var prevBeforeFen = startFen;

      // Process in parallel batches — classify incrementally.
      for (
        var batchStart = 0;
        batchStart < plies.length;
        batchStart += workerCount
      ) {
        if (!runIsCurrent()) return;
        final batchEnd = (batchStart + workerCount).clamp(0, plies.length);
        final batch = plies.sublist(batchStart, batchEnd);

        // Fire off Stockfish evals concurrently. The terminal move of a
        // mated/stalemated game gets a placeholder result: its eval is
        // synthesized from the board below, never searched.
        final results = await Future.wait([
          for (var j = 0; j < batch.length; j++)
            isTerminal(batchStart + j)
                ? Future.value(EvalResult(depth: depth))
                : pool.evaluateFen(batch[j].after.fen, depth),
        ]);
        if (!runIsCurrent()) return;

        for (var j = 0; j < results.length; j++) {
          if (!runIsCurrent()) return;
          final ply = batch[j];
          final result = results[j];
          final terminal = isTerminal(batchStart + j);
          final score = _whiteNormalizedScore(
            ply,
            result,
            terminalCheckmate: terminal && endsInCheckmate,
            terminalStalemate: terminal && endsInStalemate,
          );
          if (!terminal) {
            _shareEval(
              ply.after.fen,
              result,
              sideToMoveIsWhite: ply.after.turn == Side.white,
              depth: depth,
            );
          }

          // Measure the loss from the side that played the move.
          final isWhiteMove = ply.before.turn == Side.white;
          final loss = winningChanceLoss(
            isWhiteMove: isWhiteMove,
            before: prevWinChance,
            after: score.winChance,
          );

          // Run Maia before choosing the best line, so "interesting" moves
          // (reclassified from normal) also get the pre-move engine line.
          final maiaVerdict = maia == null
              ? null
              : await _maiaVerdict(
                  maia,
                  ply,
                  isWhiteMove ? whiteElo : blackElo,
                );
          if (!runIsCurrent()) return;

          final eval = MoveEval(
            ply: ply.ply,
            san: ply.node.san,
            fenBefore: ply.before.fen,
            fenAfter: ply.after.fen,
            scoreCp: score.cp,
            scoreMate: score.mate,
            winningChance: score.winChance,
            // The engine's line from the position *before* the move — what
            // to have played instead. One convention for every move, the
            // same one the review pass writes and every `[%pv]` reader
            // assumes; the continuation after a move is the next ply's
            // before-line anyway.
            bestLine: uciPvToSan(prevBeforeFen, prevBeforePv),
            classification: classifyMove(loss, maiaProb: maiaVerdict?.prob),
            maiaProb: maiaVerdict?.prob,
            maiaTopMove: maiaVerdict?.topMove,
            maiaTopProb: maiaVerdict?.topProb,
            depth: depth,
            deliversCheckmate: terminal && endsInCheckmate,
          );
          _evals.add(eval);
          // No [%eval] on the mating move: mate-on-board has no sign-safe
          // encoding, and the cached-restore parser derives it from the
          // board anyway.
          if (!eval.deliversCheckmate) writeEvalComment(ply.node, eval);
          prevWinChance = score.winChance;
          prevBeforePv = result.pv;
          prevBeforeFen = ply.after.fen;
        }

        _analyzedMoves = _evals.length;
        notifyListeners();
      }

      if (runIsCurrent() && onAnnotatedMovetext != null) {
        onAnnotatedMovetext(buildAnalyzedMovetext(parsed));
      }
      if (runIsCurrent()) onComplete?.call();
    } catch (e, st) {
      if (generation == _generation && !isDisposed) {
        debugPrint('[GameAnalysis] Error: $e\n$st');
      }
    } finally {
      // An older run must never mark its replacement complete.
      if (generation == _generation && !isDisposed) {
        _isAnalyzing = false;
        notifyListeners();
      }
    }
  }

  /// [result] for the position after [ply], White-normalized. A terminal
  /// move is read off the board: mate is ±1 with no engine score, stalemate
  /// an even game.
  static ({int? cp, int? mate, double winChance}) _whiteNormalizedScore(
    MainlinePly ply,
    EvalResult result, {
    required bool terminalCheckmate,
    required bool terminalStalemate,
  }) {
    if (terminalCheckmate) {
      // The side to move in the final position is the side that got mated.
      final whiteMated = ply.after.turn == Side.white;
      return (cp: null, mate: null, winChance: whiteMated ? -1.0 : 1.0);
    }
    if (terminalStalemate) {
      return (cp: 0, mate: null, winChance: cpToWinningChance(0, null));
    }
    final whiteToMove = ply.after.turn == Side.white;
    final cp = whiteToMove ? result.scoreCp : _negated(result.scoreCp);
    final mate = whiteToMove ? result.scoreMate : _negated(result.scoreMate);
    return (cp: cp, mate: mate, winChance: cpToWinningChance(cp, mate));
  }

  static int? _negated(int? value) => value == null ? null : -value;

  static int _eloOf(String? header) =>
      int.tryParse(header ?? '') ?? _kDefaultElo;

  /// The Maia evaluator once it has loaded, or null when there is none or
  /// it failed to start (logged; the pass runs without human-likelihood).
  Future<MaiaEvaluator?> _initializedMaia() async {
    final maia = MaiaFactory.instance;
    if (maia == null) return null;
    try {
      await maia.initialize();
      return maia;
    } catch (e) {
      if (kDebugMode) debugPrint('[GameAnalysis] MAIA init failed: $e');
      return null;
    }
  }

  /// Maia's probability for the move [ply] played (written onto the move as
  /// `[%maia]`) and its most likely move; null when the evaluation failed.
  Future<({double prob, String? topMove, double? topProb})?> _maiaVerdict(
    MaiaEvaluator maia,
    MainlinePly ply,
    int elo,
  ) async {
    try {
      final fenBefore = ply.before.fen;
      final maiaResult = await maia.evaluate(fenBefore, elo);
      // Standard UCI (king→destination for castling), which is the
      // vocabulary convention the policy keys use.
      final move = ply.move;
      final uci = move is NormalMove
          ? toStandardUci(ply.before, move.from, move.to)
          : move.uci;
      final prob = maiaResult.policy[uci] ?? 0.0;
      writeMaiaComment(ply.node, prob);

      final policy = maiaResult.policy;
      if (policy.isEmpty) return (prob: prob, topMove: null, topProb: null);
      var top = policy.entries.first;
      for (final entry in policy.entries) {
        if (entry.value > top.value) top = entry;
      }
      return (
        prob: prob,
        topMove: uciToSan(fenBefore, top.key),
        topProb: top.value,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[GameAnalysis] MAIA eval failed: $e');
      return null;
    }
  }

  /// Feed this ply's score into the shared persistent [EvalCache] (the store
  /// tree generation, audit, and — since the unified home — tactics mining
  /// consult), so positions this pass evaluated are never searched twice.
  /// Fire-and-forget; mates are skipped (the cache is centipawns-only).
  void _shareEval(
    String fen,
    EvalResult result, {
    required bool sideToMoveIsWhite,
    required int depth,
  }) {
    final cp = result.scoreCp;
    if (cp == null || result.scoreMate != null) return;
    EvalCache.instance.putEvalCpWhiteSoon(
      fen,
      sideToMoveIsWhite ? cp : -cp,
      depth,
    );
  }

  @override
  void cancel() {
    _generation++;
    _isCancelled = true;
    _isAnalyzing = false;
    pool.stopAll();
    notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}
