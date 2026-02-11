/// Unified Engine Pane - Single table combining Stockfish, Maia, Ease, and Probability
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chess/chess.dart' as chess;

import '../models/engine_settings.dart';
import '../services/stockfish_analysis_service.dart';
import '../services/move_analysis_pool.dart';
import '../services/maia_factory.dart';
import '../services/probability_service.dart';

/// Merged move data combining all analysis sources into a single row.
class _MergedMove {
  final String uci;
  String san;
  int? stockfishCp;
  int? stockfishMate;
  List<String> fullPv; // Full PV from Stockfish (including this move)
  double? maiaProb;    // 0.0 – 1.0
  double? dbProb;      // 0 – 100 (percentage)
  double? moveEase;    // 0.0 – 1.0 (ease of resulting position)
  int? stockfishRank;  // 1-based rank from Stockfish MultiPV

  _MergedMove({required this.uci, this.san = ''}) : fullPv = [];

  String get evalString {
    if (stockfishMate != null) {
      return 'M$stockfishMate';
    }
    if (stockfishCp != null) {
      final e = stockfishCp! / 100.0;
      return e >= 0 ? '+${e.toStringAsFixed(1)}' : e.toStringAsFixed(1);
    }
    return '--';
  }

  int get effectiveCp {
    if (stockfishMate != null) {
      return stockfishMate! > 0
          ? 10000 - stockfishMate!.abs()
          : -(10000 - stockfishMate!.abs());
    }
    return stockfishCp ?? 0;
  }

  bool get hasStockfish => stockfishCp != null || stockfishMate != null;
}

class UnifiedEnginePane extends StatefulWidget {
  final String fen;
  final bool isActive;
  final bool? isUserTurn;
  final Function(String uciMove)? onMoveSelected;
  final List<String> currentMoveSequence;
  final bool isWhiteRepertoire;

  const UnifiedEnginePane({
    super.key,
    required this.fen,
    this.isActive = true,
    this.isUserTurn,
    this.onMoveSelected,
    this.currentMoveSequence = const [],
    this.isWhiteRepertoire = true,
  });

  @override
  State<UnifiedEnginePane> createState() => _UnifiedEnginePaneState();
}

/// Cached snapshot of a completed analysis for a single FEN.
class _PositionSnapshot {
  final List<String> selectedMoveUcis;
  final Map<String, double> maiaProbs;
  final Map<String, MoveAnalysisResult> poolResults;
  final AnalysisResult stockfishAnalysis;

  _PositionSnapshot({
    required this.selectedMoveUcis,
    required this.maiaProbs,
    required this.poolResults,
    required this.stockfishAnalysis,
  });
}

class _UnifiedEnginePaneState extends State<UnifiedEnginePane> {
  final EngineSettings _settings = EngineSettings();
  final StockfishAnalysisService _stockfishService = StockfishAnalysisService();
  final MoveAnalysisPool _pool = MoveAnalysisPool();
  final ProbabilityService _probabilityService = ProbabilityService();

  // ── Per-FEN analysis cache (static — survives widget rebuilds) ──
  static final Map<String, _PositionSnapshot> _analysisCache = {};
  static const int _maxCacheSize = 50;

  Map<String, double>? _maiaProbs;
  bool _initialAnalysisStarted = false;
  bool _poolStartedForCurrentFen = false;

  /// The FEN that the current in-memory analysis state belongs to.
  /// Used to save cache entries under the correct key when the position changes
  /// (since widget.fen may already point to the *new* FEN by then).
  String? _currentAnalysisFen;

  // ── Stage 1 completion tracking ──
  // All three sources run in parallel; pool analysis starts when all finish.
  bool _stockfishComplete = false;
  bool _maiaComplete = false;
  bool _dbComplete = false;

  /// The curated set of move UCIs to display, determined after Stage 1.
  /// Empty until all three sources have reported in.
  List<String> _selectedMoveUcis = [];

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _stockfishService.isReady.addListener(_onStockfishReady);
    _stockfishService.analysis.addListener(_onMainAnalysisUpdate);
    _pool.poolStatus.addListener(_onPoolStatusChanged);

    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startInitialAnalysis();
      });
    }
  }

  void _onStockfishReady() {
    if (!_stockfishService.isReady.value || !widget.isActive || !mounted) return;

    if (kDebugMode) {
      print('[Engine] Stockfish became ready — (re)starting analysis');
    }

    // Stockfish just became ready. Two cases:
    // 1. Analysis never started → start it now.
    // 2. Analysis already started WITHOUT Stockfish (it wasn't ready
    //    at the time) → restart so Stockfish is included.
    _runAnalysis();
  }

  void _startInitialAnalysis() {
    if (!mounted || _initialAnalysisStarted) return;
    _initialAnalysisStarted = true;
    _poolStartedForCurrentFen = false;
    _selectedMoveUcis = [];

    final shortFen = widget.fen.split(' ').take(2).join(' ');

    // Track which FEN this analysis belongs to (for correct cache saving)
    _currentAnalysisFen = widget.fen;

    // ── Check cache first — instant restore if we've seen this FEN ──
    final cached = _analysisCache[widget.fen];
    if (cached != null) {
      if (kDebugMode) {
        print('[Engine] Cache HIT for $shortFen — restoring snapshot');
      }
      _restoreFromCache(cached);
      return;
    }

    // Determine which sources are available
    final useStockfish =
        _settings.showStockfish && _stockfishService.isReady.value;
    final useMaia = _settings.showMaia &&
        MaiaFactory.isAvailable &&
        MaiaFactory.instance != null;
    final useDb = _settings.showProbability;

    if (kDebugMode) {
      print('[Engine] ── Stage 1 START for $shortFen ──');
      print('[Engine]   Stockfish: ${useStockfish ? "ON" : "OFF (ready=${_stockfishService.isReady.value})"}');
      print('[Engine]   Maia: ${useMaia ? "ON" : "OFF (available=${MaiaFactory.isAvailable}, instance=${MaiaFactory.instance != null})"}');
      print('[Engine]   DB: ${useDb ? "ON" : "OFF"}');
    }

    // Mark unavailable sources as already complete
    _stockfishComplete = !useStockfish;
    _maiaComplete = !useMaia;
    _dbComplete = !useDb;

    // ── Stage 1: fire all three sources in parallel ──
    if (useStockfish) _stockfishService.startAnalysis(widget.fen);
    if (useMaia) _runMaiaAnalysis();
    if (useDb) _calculateCumulativeProbability();

    // If every source was disabled, proceed immediately
    _checkStage1Complete();
  }

  @override
  void didUpdateWidget(UnifiedEnginePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive &&
        (widget.fen != oldWidget.fen || !oldWidget.isActive)) {
      _runAnalysis();
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _stockfishService.isReady.removeListener(_onStockfishReady);
    _stockfishService.analysis.removeListener(_onMainAnalysisUpdate);
    _pool.poolStatus.removeListener(_onPoolStatusChanged);

    // Stop analysis and tear down pool workers to free OS processes / RAM.
    // The singletons survive — workers are recreated by _ensureWorkers()
    // next time the repertoire builder is opened.
    _stockfishService.stopAnalysis();
    _pool.cancel();
    _pool.dispose();

    super.dispose();
  }

  void _onSettingsChanged() {
    // Invalidate cache for current FEN — settings changed means fresh analysis
    _analysisCache.remove(widget.fen);
    setState(() {});
    if (widget.isActive) {
      _stockfishService.updateSettings();
      _runAnalysis();
    }
  }

  void _runAnalysis() {
    if (kDebugMode) {
      final shortFen = widget.fen.split(' ').take(2).join(' ');
      print('[Engine] ── _runAnalysis() for $shortFen ──');
    }

    // Save current analysis to cache before switching (if complete)
    _trySaveCurrentToCache();

    // Cancel any in-progress pool work (stale FEN)
    _pool.cancel();
    _initialAnalysisStarted = false;
    _startInitialAnalysis();
  }

  // ── Analysis Cache ──────────────────────────────────────────────────────

  /// Restore a cached snapshot — sets all state and notifiers so the table
  /// renders instantly without any engine work.
  void _restoreFromCache(_PositionSnapshot cached) {
    _selectedMoveUcis = List.from(cached.selectedMoveUcis);
    _maiaProbs = Map.from(cached.maiaProbs);
    _pool.results.value = Map.from(cached.poolResults);
    _stockfishService.analysis.value = cached.stockfishAnalysis;

    // Mark everything as done so no analysis starts
    _stockfishComplete = true;
    _maiaComplete = true;
    _dbComplete = true;
    _poolStartedForCurrentFen = true;

    _pool.poolStatus.value = PoolStatus(
      phase: 'complete',
      totalMoves: cached.selectedMoveUcis.length,
      completedMoves: cached.poolResults.length,
    );

    // Still refresh DB probabilities (fast network/cache call)
    if (_settings.showProbability) {
      _calculateCumulativeProbability();
    }

    setState(() {});
  }

  /// Save completed analysis for the current FEN to cache.
  void _trySaveCurrentToCache() {
    // Only cache if analysis is complete and we have data
    if (_selectedMoveUcis.isEmpty || _maiaProbs == null) return;
    if (!_pool.poolStatus.value.isComplete) return;

    // Use the FEN that this analysis was started for, NOT widget.fen,
    // because widget.fen may already point to a new position if
    // didUpdateWidget fired before this save.
    final fen = _currentAnalysisFen;
    if (fen == null) return;
    _analysisCache[fen] = _PositionSnapshot(
      selectedMoveUcis: List.from(_selectedMoveUcis),
      maiaProbs: Map.from(_maiaProbs!),
      poolResults: Map.from(_pool.results.value),
      stockfishAnalysis: _stockfishService.analysis.value,
    );

    // Evict oldest entries if cache is too large
    while (_analysisCache.length > _maxCacheSize) {
      _analysisCache.remove(_analysisCache.keys.first);
    }
  }

  /// Called when pool status changes — save to cache when complete.
  void _onPoolStatusChanged() {
    final ps = _pool.poolStatus.value;
    if (ps.isComplete) {
      if (kDebugMode) {
        final res = _pool.results.value;
        final withEase = res.values.where((r) => r.moveEase != null).length;
        print('[Engine] ── Stage 2 COMPLETE — '
            '${res.length} evals, $withEase with ease ──');
        for (final e in res.entries) {
          final r = e.value;
          final easeStr = r.moveEase != null
              ? r.moveEase!.toStringAsFixed(3)
              : 'null';
          print('[Engine]   ${_uciToSan(e.key)}: '
              'cp=${r.scoreCp}, mate=${r.scoreMate}, '
              'ease=$easeStr');
        }
      }
      _trySaveCurrentToCache();
    }
  }

  /// Called when the main MultiPV analysis updates.
  void _onMainAnalysisUpdate() {
    final result = _stockfishService.analysis.value;
    if (result.isComplete && !_stockfishComplete) {
      if (kDebugMode) {
        print('[Engine]   Stockfish DONE — '
            '${result.lines.length} lines, '
            'depth ${result.depth}, '
            'moves: ${result.lines.map((l) => l.pv.isNotEmpty ? l.pv.first : "?").join(", ")}');
      }
      _stockfishComplete = true;
      _checkStage1Complete();
    }
  }

  /// When all three Stage 1 sources are done, select moves and start Stage 2.
  void _checkStage1Complete() {
    if (!_stockfishComplete || !_maiaComplete || !_dbComplete) {
      if (kDebugMode) {
        print('[Engine]   Stage 1 check: SF=$_stockfishComplete, '
            'Maia=$_maiaComplete, DB=$_dbComplete — waiting');
      }
      return;
    }
    if (_poolStartedForCurrentFen || !widget.isActive || !mounted) {
      if (kDebugMode) {
        print('[Engine]   Stage 1 all done but skipping pool: '
            'poolStarted=$_poolStartedForCurrentFen, '
            'active=${widget.isActive}, mounted=$mounted');
      }
      return;
    }
    if (kDebugMode) {
      print('[Engine] ── Stage 1 COMPLETE — selecting moves for pool ──');
    }
    _selectMovesAndStartPool();
  }

  /// Select the curated set of moves and kick off the parallel pool.
  ///
  /// Move selection priority:
  ///   1. Stockfish MultiPV (top N guaranteed slots)
  ///   2. Remaining slots filled by Maia + DB candidates, interleaved
  ///      by probability (highest first), up to [EngineSettings.maxAnalysisMoves].
  void _selectMovesAndStartPool() {
    _poolStartedForCurrentFen = true;

    // ── 1. Stockfish top N (guaranteed) ──────────────────────────────────
    final stockfishUcis = <String>[];
    for (final line in _stockfishService.analysis.value.lines) {
      if (line.pv.isNotEmpty) stockfishUcis.add(line.pv.first);
    }

    // ── 2. Collect Maia + DB candidates with normalised probability ──────
    //    Both are normalised to percentage (0-100) for fair comparison.
    final candidateProbs = <String, double>{};

    if (_maiaProbs != null) {
      for (final e in _maiaProbs!.entries) {
        if (e.value < 0.005) continue; // skip noise
        candidateProbs[e.key] = e.value * 100; // 0-1 → 0-100
      }
    }

    final dbData = _probabilityService.currentPosition.value;
    if (dbData != null) {
      for (final dbm in dbData.moves) {
        if (dbm.uci.isEmpty) continue;
        final existing = candidateProbs[dbm.uci];
        if (existing == null || dbm.probability > existing) {
          candidateProbs[dbm.uci] = dbm.probability;
        }
      }
    }

    // Remove moves already covered by Stockfish MultiPV
    for (final uci in stockfishUcis) {
      candidateProbs.remove(uci);
    }

    // ── 3. Sort candidates by probability (highest first) ────────────────
    final sortedCandidates = candidateProbs.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // ── 4. Fill remaining slots ──────────────────────────────────────────
    final maxMoves = _settings.maxAnalysisMoves;
    final remainingSlots =
        (maxMoves - stockfishUcis.length).clamp(0, maxMoves);
    final extraUcis =
        sortedCandidates.take(remainingSlots).map((e) => e.key).toList();

    // ── 5. Final curated list ────────────────────────────────────────────
    _selectedMoveUcis = [...stockfishUcis, ...extraUcis];
    setState(() {}); // repaint table with selected moves

    if (kDebugMode) {
      print('[Engine] ── Move Selection ──');
      print('[Engine]   Stockfish MultiPV (${stockfishUcis.length}): '
          '${stockfishUcis.map((u) => _uciToSan(u)).join(", ")}');
      print('[Engine]   Maia+DB candidates (${candidateProbs.length}): '
          '${sortedCandidates.take(8).map((e) => "${_uciToSan(e.key)}(${e.value.toStringAsFixed(1)}%)").join(", ")}');
      print('[Engine]   Extra slots: $remainingSlots → '
          '${extraUcis.map((u) => _uciToSan(u)).join(", ")}');
      print('[Engine]   Total selected (${_selectedMoveUcis.length}): '
          '${_selectedMoveUcis.map((u) => _uciToSan(u)).join(", ")}');
    }

    // ── 6. Start Stage 2 — pool eval + ease for all selected moves ──────
    //    MultiPV moves already have evals but still need ease computation
    //    (the pool evaluates the *resulting* position, which is needed for ease).
    if (_selectedMoveUcis.isNotEmpty) {
      if (kDebugMode) {
        print('[Engine] ── Stage 2 START — pool analyzing '
            '${_selectedMoveUcis.length} moves ──');
      }
      _pool.analyzeMovesParallel(
        baseFen: widget.fen,
        movesToAnalyze: _selectedMoveUcis,
        evalDepth: _settings.depth,
        easeDepth: _settings.easeDepth,
        numWorkers: _settings.cores,
      );
    } else {
      if (kDebugMode) {
        print('[Engine]   No moves to analyze — pool skipped');
      }
    }
  }

  Future<void> _runMaiaAnalysis() async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      if (kDebugMode) {
        print('[Engine]   Maia SKIPPED — not available');
      }
      _maiaComplete = true;
      _checkStage1Complete();
      return;
    }

    try {
      final probs =
          await MaiaFactory.instance!.evaluate(widget.fen, _settings.maiaElo);
      if (mounted) {
        setState(() {
          _maiaProbs = probs;
        });
      }
      if (kDebugMode) {
        final topMoves = (probs.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(5)
            .map((e) => '${e.key}(${(e.value * 100).toStringAsFixed(1)}%)')
            .join(', ');
        print('[Engine]   Maia DONE — ${probs.length} moves, top: $topMoves');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[Engine]   Maia FAILED — $e');
      }
    } finally {
      _maiaComplete = true;
      _checkStage1Complete();
    }
  }

  Future<void> _calculateCumulativeProbability() async {
    try {
      await _probabilityService.fetchProbabilities(widget.fen);

      if (kDebugMode) {
        final dbData = _probabilityService.currentPosition.value;
        final moveCount = dbData?.moves.length ?? 0;
        final topMoves = dbData != null
            ? (dbData.moves.toList()
                  ..sort((a, b) => b.probability.compareTo(a.probability)))
                .take(5)
                .map((m) => '${m.san}(${m.probability.toStringAsFixed(1)}%)')
                .join(', ')
            : 'none';
        print('[Engine]   DB DONE — $moveCount moves, top: $topMoves');
      }

      if (widget.currentMoveSequence.isEmpty) {
        _probabilityService.cumulativeProbability.value = 100.0;
        return;
      }

      await _probabilityService.calculateCumulativeProbability(
        widget.currentMoveSequence,
        isUserWhite: widget.isWhiteRepertoire,
        startingMoves: _settings.probabilityStartMoves,
      );
    } catch (e) {
      if (kDebugMode) {
        print('[Engine]   DB FAILED — $e');
      }
    } finally {
      _dbComplete = true;
      _checkStage1Complete();
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return const Center(child: Text('Analysis paused'));
    }

    return Column(
      children: [
        _buildSettingsBar(),
        const Divider(height: 1),
        Expanded(child: _buildUnifiedMoveTable()),
        _buildCompactFooter(),
      ],
    );
  }

  Widget _buildSettingsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                _stockfishService.status,
                _pool.poolStatus,
              ]),
              builder: (context, _) {
                final ps = _pool.poolStatus.value;

                if (ps.isAnalyzing) {
                  final sans = ps.evaluatingUcis
                      .map((u) => _uciToSan(u))
                      .join(', ');
                  final totalRam =
                      ps.hashPerWorkerMb * ps.activeWorkers;
                  return Text(
                    'Evaluating ${ps.completedMoves}/${ps.totalMoves}: '
                    '$sans  |  '
                    'Workers: ${ps.activeWorkers}  |  '
                    '${_formatRam(totalRam)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                    overflow: TextOverflow.ellipsis,
                  );
                }

                if (ps.isComplete) {
                  return Text(
                    '${ps.totalMoves} moves analyzed',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  );
                }

                // During Stage 1 — show Stockfish MultiPV status
                return Text(
                  _stockfishService.status.value,
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: 'Engine Settings',
            onPressed: _showSettingsDialog,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  // ─── Unified Move Table ─────────────────────────────────────────────────

  Widget _buildUnifiedMoveTable() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _stockfishService.analysis,
        _stockfishService.isReady,
        _pool.results,
        _probabilityService.currentPosition,
      ]),
      builder: (context, _) {
        // Show loading if nothing is ready yet
        if (!_stockfishService.isReady.value &&
            _maiaProbs == null &&
            _probabilityService.currentPosition.value == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Initializing analysis...',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }

        final moves = _mergeMoves();

        if (moves.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          children: [
            _buildTableHeader(),
            const Divider(height: 1),
            ...moves.map(_buildMoveRow),
          ],
        );
      },
    );
  }

  Widget _buildTableHeader() {
    final headerStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: Colors.grey[500],
      letterSpacing: 0.5,
    );

    final dbData = _probabilityService.currentPosition.value;
    final gameCountStr = dbData != null
        ? ' (${_formatCount(dbData.totalGames)})'
        : '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text('MOVE', style: headerStyle),
          ),
          SizedBox(
            width: 58,
            child: Text('EVAL', style: headerStyle, textAlign: TextAlign.center),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text('LINE', style: headerStyle),
          ),
          if (_settings.showProbability)
            SizedBox(
              width: 46,
              child: Tooltip(
                message: 'Database probability$gameCountStr',
                child: Text('DB',
                    style: headerStyle, textAlign: TextAlign.right),
              ),
            ),
          if (_settings.showMaia)
            SizedBox(
              width: 46,
              child: Tooltip(
                message: 'Maia ${_settings.maiaElo} prediction',
                child: Text('MAIA',
                    style: headerStyle, textAlign: TextAlign.right),
              ),
            ),
          if (_settings.showEase)
            SizedBox(
              width: 46,
              child: Tooltip(
                message:
                    'Difficulty for opponent after this move\n'
                    'Higher = harder for them to respond well',
                child: Text('EASE',
                    style: headerStyle, textAlign: TextAlign.right),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMoveRow(_MergedMove move) {
    final evalColor = move.hasStockfish
        ? (move.effectiveCp > 50
            ? Colors.green
            : (move.effectiveCp < -50 ? Colors.red : Colors.grey))
        : Colors.grey[700]!;

    final continuation = _formatContinuation(move.fullPv);

    return InkWell(
      onTap: () => widget.onMoveSelected?.call(move.uci),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Move (SAN)
            SizedBox(
              width: 52,
              child: Text(
                move.san,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  fontSize: 15,
                ),
              ),
            ),
            // Eval badge
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: move.hasStockfish
                    ? evalColor.withAlpha(25)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                move.evalString,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: evalColor,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 8),
            // PV continuation
            Expanded(
              child: Text(
                continuation,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  fontFamily: 'monospace',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            // DB probability
            if (_settings.showProbability)
              SizedBox(
                width: 46,
                child: Text(
                  move.dbProb != null
                      ? '${move.dbProb!.toStringAsFixed(0)}%'
                      : '--',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    color: move.dbProb != null
                        ? Colors.cyan[300]
                        : Colors.grey[700],
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            // Maia probability
            if (_settings.showMaia)
              SizedBox(
                width: 46,
                child: Text(
                  move.maiaProb != null
                      ? '${(move.maiaProb! * 100).toStringAsFixed(0)}%'
                      : '--',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    color: move.maiaProb != null
                        ? Colors.purple[300]
                        : Colors.grey[700],
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            // Ease (displayed as 1.0 - moveEase)
            if (_settings.showEase)
              SizedBox(
                width: 46,
                child: Text(
                  move.moveEase != null
                      ? (1.0 - move.moveEase!).toStringAsFixed(2)
                      : '--',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        move.moveEase != null ? FontWeight.w500 : FontWeight.normal,
                    color: move.moveEase != null
                        ? Colors.amber[300]
                        : Colors.grey[700],
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─── Footer ─────────────────────────────────────────────────────────────

  Widget _buildCompactFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Overall ease (computed from MultiPV + pool evals + Maia)
          if (_settings.showEase) ...[
            ListenableBuilder(
              listenable: Listenable.merge([
                _pool.results,
                _stockfishService.analysis,
                _pool.poolStatus,
              ]),
              builder: (_, __) {
                final ease = _computeOverallEase();
                final isAnalyzing =
                    _pool.poolStatus.value.isAnalyzing;
                if (ease == null) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Ease ',
                        style: TextStyle(
                            fontSize: 15, color: Colors.grey[500]),
                      ),
                      if (isAnalyzing)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      else
                        Text(
                          '--',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[500]),
                        ),
                    ],
                  );
                }

                return Tooltip(
                  message:
                      'How easily a human finds a good move here\n'
                      'Higher = easier for side to move\n'
                      'Raw: ${ease.toStringAsFixed(3)}',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Ease ',
                        style:
                            TextStyle(fontSize: 15, color: Colors.grey[500]),
                      ),
                      Text(
                        ease.toStringAsFixed(2),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber[300],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: 20),
          ],

          // Cumulative probability
          if (_settings.showProbability) ...[
            ValueListenableBuilder<double>(
              valueListenable: _probabilityService.cumulativeProbability,
              builder: (_, cumulative, __) {
                return Tooltip(
                  message: 'Cumulative probability along this line',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Cumulative DB ',
                        style:
                            TextStyle(fontSize: 15, color: Colors.grey[500]),
                      ),
                      Text(
                        '${cumulative.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.cyan[300],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],

          const Spacer(),

          // DB game count
          if (_settings.showProbability)
            ValueListenableBuilder<PositionProbabilities?>(
              valueListenable: _probabilityService.currentPosition,
              builder: (_, posData, __) {
                if (posData == null || posData.totalGames == 0) {
                  return const SizedBox.shrink();
                }
                return Text(
                  '${_formatCount(posData.totalGames)} games',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                );
              },
            ),
        ],
      ),
    );
  }

  // ─── Merge Logic ────────────────────────────────────────────────────────

  List<_MergedMove> _mergeMoves() {
    final byUci = <String, _MergedMove>{};

    // ── Phase 1: Determine which moves to show ──────────────────────────
    //
    // Before Stage 1 completes, show Stockfish MultiPV lines progressively
    // so the user sees results as they arrive.
    // After Stage 1, show only the curated _selectedMoveUcis.

    if (_selectedMoveUcis.isEmpty) {
      // Still gathering data — show Stockfish lines as they stream in
      if (_settings.showStockfish) {
        for (final line in _stockfishService.analysis.value.lines) {
          if (line.pv.isEmpty) continue;
          final uci = line.pv.first;
          final m = byUci.putIfAbsent(uci, () => _MergedMove(uci: uci));
          m.stockfishCp = line.scoreCp;
          m.stockfishMate = line.scoreMate;
          m.fullPv = line.pv;
          m.stockfishRank = line.pvNumber;
        }
      }
    } else {
      // Stage 1 done — show curated selection only
      for (final uci in _selectedMoveUcis) {
        byUci[uci] = _MergedMove(uci: uci);
      }

      // Fill Stockfish MultiPV data for those moves
      for (final line in _stockfishService.analysis.value.lines) {
        if (line.pv.isEmpty) continue;
        final m = byUci[line.pv.first];
        if (m != null) {
          m.stockfishCp = line.scoreCp;
          m.stockfishMate = line.scoreMate;
          m.fullPv = line.pv;
          m.stockfishRank = line.pvNumber;
        }
      }
    }

    // ── Phase 2: Fill ALL columns from ALL sources ──────────────────────

    final dbData = _probabilityService.currentPosition.value;
    final poolResults = _pool.results.value;

    for (final m in byUci.values) {
      // Pool results: eval + ease
      final poolResult = poolResults[m.uci];
      if (poolResult != null) {
        if (!m.hasStockfish && poolResult.hasEval) {
          m.stockfishCp = poolResult.scoreCp;
          m.stockfishMate = poolResult.scoreMate;
          m.fullPv = poolResult.pv;
        }
        if (m.moveEase == null && poolResult.moveEase != null) {
          m.moveEase = poolResult.moveEase;
        }
      }

      // Maia probability — 0% if Maia has loaded but doesn't list this move
      if (m.maiaProb == null && _maiaProbs != null) {
        m.maiaProb = _maiaProbs![m.uci] ?? 0.0;
      }

      // Database probability — 0% if DB has loaded but doesn't list this move
      if (m.dbProb == null && dbData != null) {
        double? found;
        for (final dbm in dbData.moves) {
          if (dbm.uci == m.uci) {
            found = dbm.probability;
            if (m.san.isEmpty) m.san = dbm.san;
            break;
          }
        }
        m.dbProb = found ?? 0.0;
      }

      // UCI → SAN fallback
      if (m.san.isEmpty) {
        m.san = _uciToSan(m.uci);
      }
    }

    // ── Phase 3: Sort ──────────────────────────────────────────────────
    // MultiPV-ranked moves first (by rank), then by eval, then probability.
    final result = byUci.values.toList();
    result.sort((a, b) {
      if (a.stockfishRank != null && b.stockfishRank != null) {
        return a.stockfishRank!.compareTo(b.stockfishRank!);
      }
      if (a.stockfishRank != null) return -1;
      if (b.stockfishRank != null) return 1;
      if (a.hasStockfish && b.hasStockfish) {
        return b.effectiveCp.compareTo(a.effectiveCp);
      }
      if (a.hasStockfish) return -1;
      if (b.hasStockfish) return 1;
      final aMaia = a.maiaProb ?? 0.0;
      final bMaia = b.maiaProb ?? 0.0;
      if (aMaia != bMaia) return bMaia.compareTo(aMaia);
      return (b.dbProb ?? 0.0).compareTo(a.dbProb ?? 0.0);
    });

    return result;
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  String _uciToSan(String uci) {
    try {
      final game = chess.Chess.fromFEN(widget.fen);
      final from = uci.substring(0, 2);
      final to = uci.substring(2, 4);
      String? promotion;
      if (uci.length > 4) promotion = uci.substring(4);

      final legalMoves = game.moves({'verbose': true});
      final match = legalMoves.firstWhere(
        (m) =>
            m['from'] == from &&
            m['to'] == to &&
            (promotion == null || m['promotion'] == promotion),
        orElse: () => <String, dynamic>{},
      );

      return match.isNotEmpty ? match['san'] as String : uci;
    } catch (e) {
      return uci;
    }
  }

  /// Format the PV continuation, skipping the first move (shown in the Move column).
  String _formatContinuation(List<String> fullPv) {
    if (fullPv.length <= 1) return '';

    final game = chess.Chess.fromFEN(widget.fen);
    final sanMoves = <String>[];

    for (int i = 0; i < fullPv.length && sanMoves.length < 6; i++) {
      final uci = fullPv[i];
      if (uci.length < 4) continue;

      final from = uci.substring(0, 2);
      final to = uci.substring(2, 4);
      String? promotion;
      if (uci.length > 4) promotion = uci.substring(4);

      final moveMap = <String, String>{'from': from, 'to': to};
      if (promotion != null) moveMap['promotion'] = promotion;

      final legalMoves = game.moves({'verbose': true});
      final matchingMove = legalMoves.firstWhere(
        (m) =>
            m['from'] == from &&
            m['to'] == to &&
            (promotion == null || m['promotion'] == promotion),
        orElse: () => <String, dynamic>{},
      );

      if (matchingMove.isNotEmpty && game.move(moveMap)) {
        // Skip the first move — it's already displayed as the row's SAN
        if (i >= 1) {
          sanMoves.add(matchingMove['san'] as String);
        }
      } else {
        break;
      }
    }

    return sanMoves.join(' ');
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(0)}k';
    return count.toString();
  }

  String _formatRam(int mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '$mb MB';
  }

  // ─── Overall Ease Computation ──────────────────────────────────────────

  /// Compute the overall ease of the current position from MultiPV + pool
  /// eval results + Maia probabilities. Returns null if insufficient data.
  double? _computeOverallEase() {
    if (_maiaProbs == null) return null;

    final fenParts = widget.fen.split(' ');
    final isWhiteTurn = fenParts.length >= 2 && fenParts[1] == 'w';

    // maxQ from MultiPV top line (best eval of current position)
    final multiPvLines = _stockfishService.analysis.value.lines;
    if (multiPvLines.isEmpty) return null;

    final topCp = multiPvLines.first.effectiveCp;
    // MultiPV eval is White-normalized; convert to side-to-move
    final rootCp = isWhiteTurn ? topCp : -topCp;
    final maxQ = scoreToQ(rootCp);

    // Sorted Maia candidates
    final sorted = _maiaProbs!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final poolResults = _pool.results.value;
    double sumWeightedRegret = 0.0;
    double cumulativeProb = 0.0;
    int found = 0;
    int skippedNoEval = 0;

    for (final entry in sorted) {
      if (entry.value < 0.01) continue;

      // Get this move's eval (White-normalized cp)
      int? whiteCp;
      String source = '';

      // Check MultiPV first
      for (final line in multiPvLines) {
        if (line.pv.isNotEmpty && line.pv.first == entry.key) {
          whiteCp = line.effectiveCp;
          source = 'MultiPV';
          break;
        }
      }
      // Check pool results
      if (whiteCp == null) {
        final pr = poolResults[entry.key];
        if (pr != null && pr.hasEval) {
          whiteCp = pr.effectiveCp;
          source = 'Pool';
        }
      }
      if (whiteCp == null) {
        skippedNoEval++;
        continue;
      }

      // Convert to side-to-move perspective
      final moveCp = isWhiteTurn ? whiteCp : -whiteCp;
      final qVal = scoreToQ(moveCp);

      final regret = math.max(0.0, maxQ - qVal);
      sumWeightedRegret += math.pow(entry.value, kEaseBeta) * regret;

      found++;
      cumulativeProb += entry.value;
      if (cumulativeProb > 0.90) break;
    }

    if (found == 0) {
      // Only log once when pool is complete (avoid spam during analysis)
      if (kDebugMode && _pool.poolStatus.value.isComplete) {
        print('[Engine] Overall ease: null — '
            'found=0, skippedNoEval=$skippedNoEval, '
            'maiaProbs=${_maiaProbs!.length}, '
            'multiPV=${multiPvLines.length}, '
            'poolResults=${poolResults.length}');
      }
      return null;
    }

    final ease = 1.0 - math.pow(sumWeightedRegret / 2, kEaseAlpha);
    return ease;
  }

  // ─── Dialogs ────────────────────────────────────────────────────────────

  void _showSettingsDialog() {
    final probController =
        TextEditingController(text: _settings.probabilityStartMoves);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Analysis Settings'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Sources ──
                  Text('Sources',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[400])),
                  _buildToggleTile('Stockfish', _settings.showStockfish, (v) {
                    _settings.showStockfish = v;
                    setDialogState(() {});
                  }),
                  _buildToggleTile('Maia', _settings.showMaia, (v) {
                    _settings.showMaia = v;
                    setDialogState(() {});
                  }),
                  _buildToggleTile('Ease', _settings.showEase, (v) {
                    _settings.showEase = v;
                    setDialogState(() {});
                  }),
                  _buildToggleTile('Probability', _settings.showProbability,
                      (v) {
                    _settings.showProbability = v;
                    setDialogState(() {});
                  }),

                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 8),

                  // ── Stockfish Engine ──
                  Text('Stockfish Engine',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[400])),
                  const SizedBox(height: 4),
                  Text(
                    'System: ${EngineSettings.systemCores} cores, '
                    '${_formatRam(EngineSettings.systemRamMb)} RAM',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 8),
                  _buildNumberField(
                    label: 'Parallel Workers',
                    value: _settings.cores,
                    min: 1,
                    max: EngineSettings.systemCores.clamp(1, 32),
                    onChanged: (v) {
                      _settings.cores = v;
                      setDialogState(() {});
                    },
                  ),
                  _buildNumberField(
                    label: 'Max System Load (%)',
                    value: _settings.maxSystemLoad,
                    min: 50,
                    max: 100,
                    step: 5,
                    onChanged: (v) {
                      _settings.maxSystemLoad = v;
                      setDialogState(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      'Skip workers if CPU or RAM exceeds this',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic),
                    ),
                  ),
                  _buildNumberField(
                    label: 'Total RAM (MB)',
                    value: _settings.hashMb,
                    min: 64,
                    max: (EngineSettings.systemRamMb * 0.8).round().clamp(64, EngineSettings.systemRamMb),
                    step: 64,
                    onChanged: (v) {
                      _settings.hashMb = v;
                      setDialogState(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      '${_settings.hashPerWorker} MB per instance '
                      '(${_settings.cores} workers + 1 MultiPV)',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic),
                    ),
                  ),
                  _buildNumberField(
                    label: 'Eval Depth',
                    value: _settings.depth,
                    min: 1,
                    max: 99,
                    onChanged: (v) {
                      _settings.depth = v;
                      setDialogState(() {});
                    },
                  ),
                  _buildNumberField(
                    label: 'Ease Depth',
                    value: _settings.easeDepth,
                    min: 1,
                    max: 99,
                    onChanged: (v) {
                      _settings.easeDepth = v;
                      setDialogState(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      'Lower = faster ease (runs per Maia candidate)',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic),
                    ),
                  ),
                  _buildNumberField(
                    label: 'MultiPV (Lines)',
                    value: _settings.multiPv,
                    min: 1,
                    max: 10,
                    onChanged: (v) {
                      _settings.multiPv = v;
                      setDialogState(() {});
                    },
                  ),
                  _buildNumberField(
                    label: 'Max Moves',
                    value: _settings.maxAnalysisMoves,
                    min: 3,
                    max: 20,
                    onChanged: (v) {
                      _settings.maxAnalysisMoves = v;
                      setDialogState(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      'MultiPV lines + top Maia/DB candidates '
                      '(${_settings.maxAnalysisMoves - _settings.multiPv} '
                      'extra slots)',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic),
                    ),
                  ),

                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 8),

                  // ── Probability ──
                  Text('Probability',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[400])),
                  const SizedBox(height: 8),
                  Text(
                    'Starting Moves',
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey[300]),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: probController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'e.g., 1. d4 d5 2. c4',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 13),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Leave empty for initial position',
                    style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 11,
                        fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  // Apply probability starting moves on close
                  final newStartMoves = probController.text;
                  if (newStartMoves != _settings.probabilityStartMoves) {
                    _settings.probabilityStartMoves = newStartMoves;
                    _calculateCumulativeProbability();
                  }
                  Navigator.pop(context);
                },
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildToggleTile(
      String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(label),
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }

  Widget _buildNumberField({
    required String label,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: value > min
                ? () => onChanged((value - step).clamp(min, max))
                : null,
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          SizedBox(
            width: 50,
            child: Text(
              value.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: value < max
                ? () => onChanged((value + step).clamp(min, max))
                : null,
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
