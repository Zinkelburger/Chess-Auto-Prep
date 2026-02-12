/// Unified Engine Pane - Single table combining Stockfish, Maia, Ease, and Probability
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/move_analysis_pool.dart';
import '../../services/maia_factory.dart';
import '../../services/probability_service.dart';
import '../../utils/chess_utils.dart';
import 'engine_settings_dialog.dart';
import 'engine_pane_footer.dart';

/// Lightweight stopwatch helper for timestamped performance logging.
Stopwatch? _perfWatch;
void _perfLog(String msg) {
  if (!kDebugMode) return;
  _perfWatch ??= Stopwatch();
  final ms = _perfWatch!.elapsedMilliseconds;
  print('[Perf ${ms.toString().padLeft(6)}ms] $msg');
}
void _perfReset() {
  _perfWatch = Stopwatch()..start();
}

/// Merged move data combining all analysis sources into a single row.
class _MergedMove {
  final String uci;
  String san = '';
  int? stockfishCp;
  int? stockfishMate;
  List<String> fullPv = []; // Full PV from Stockfish (including this move)
  double? maiaProb;    // 0.0 – 1.0
  double? dbProb;      // 0 – 100 (percentage)
  double? moveEase;    // 0.0 – 1.0 (ease of resulting position)
  int? stockfishRank;  // 1-based rank from Stockfish MultiPV

  _MergedMove({required this.uci});

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
  final DiscoveryResult discoveryResult;

  _PositionSnapshot({
    required this.selectedMoveUcis,
    required this.maiaProbs,
    required this.poolResults,
    required this.discoveryResult,
  });
}

class _UnifiedEnginePaneState extends State<UnifiedEnginePane> {
  final EngineSettings _settings = EngineSettings();
  final MoveAnalysisPool _pool = MoveAnalysisPool();
  final ProbabilityService _probabilityService = ProbabilityService();

  // ── Per-FEN analysis cache (static — survives widget rebuilds) ──
  static final Map<String, _PositionSnapshot> _analysisCache = {};
  static const int _maxCacheSize = 50;

  Map<String, double>? _maiaProbs;
  bool _initialAnalysisStarted = false;

  /// The FEN that the current in-memory analysis state belongs to.
  String? _currentAnalysisFen;

  /// Generation counter for cancelling stale async work.
  int _analysisGeneration = 0;

  /// The curated set of move UCIs to display, built after all sources complete.
  List<String> _selectedMoveUcis = [];

  /// User-controlled on/off switch (persists across rebuilds via static).
  static bool _engineEnabled = true;

  /// Whether analysis should run right now.
  bool get _isActive => widget.isActive && _engineEnabled;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _pool.poolStatus.addListener(_onPoolStatusChanged);

    if (_isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startInitialAnalysis();
      });
    }
  }

  @override
  void didUpdateWidget(UnifiedEnginePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isActive &&
        (widget.fen != oldWidget.fen || !oldWidget.isActive)) {
      _runAnalysis();
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _pool.poolStatus.removeListener(_onPoolStatusChanged);
    _pool.cancel();
    super.dispose();
  }

  void _onSettingsChanged() {
    _analysisCache.remove(widget.fen);
    setState(() {});
    if (_isActive) {
      _runAnalysis();
    }
  }

  void _runAnalysis() {
    if (kDebugMode) {
      final shortFen = widget.fen.split(' ').take(2).join(' ');
      print('[Engine] ── _runAnalysis() for $shortFen ──');
    }

    _trySaveCurrentToCache();
    _analysisGeneration++;
    _initialAnalysisStarted = false;
    _startInitialAnalysis();
  }

  // ── Analysis Pipeline ─────────────────────────────────────────────────

  Future<void> _startInitialAnalysis() async {
    if (!mounted || _initialAnalysisStarted) return;
    _initialAnalysisStarted = true;
    _selectedMoveUcis = [];
    _maiaProbs = null;

    final myGen = ++_analysisGeneration;
    final shortFen = widget.fen.split(' ').take(2).join(' ');

    _perfReset();
    _perfLog('_startInitialAnalysis BEGIN for $shortFen');
    _currentAnalysisFen = widget.fen;

    // ── Check cache ──
    final cached = _analysisCache[widget.fen];
    if (cached != null) {
      _perfLog('Cache HIT — restoring snapshot');
      _restoreFromCache(cached);
      return;
    }

    final useStockfish = _settings.showStockfish;
    final useMaia = _settings.showMaia &&
        MaiaFactory.isAvailable &&
        MaiaFactory.instance != null;
    final useDb = _settings.showProbability;

    _perfLog('Pipeline START — SF=${useStockfish ? "ON" : "OFF"}, '
        'Maia=${useMaia ? "ON" : "OFF"}, DB=${useDb ? "ON" : "OFF"}');

    // ── Fire all sources in parallel ──
    final discoveryFuture = useStockfish
        ? _pool.runDiscovery(
            fen: widget.fen,
            depth: _settings.depth,
            multiPv: _settings.multiPv,
          )
        : Future.value(const DiscoveryResult());

    final maiaFuture = useMaia
        ? _runMaiaAnalysis()
        : Future.value(<String, double>{});

    final dbFuture = useDb ? _fetchDbData() : Future.value(null);

    // ── Await all ──
    final results = await Future.wait<Object?>([
      discoveryFuture,
      maiaFuture,
      dbFuture,
    ]);

    if (!mounted || _analysisGeneration != myGen) return;

    final discovery = results[0] as DiscoveryResult;
    _maiaProbs = results[1] as Map<String, double>;
    final dbData = _probabilityService.currentPosition.value;

    _perfLog('All sources complete');

    // ── Filter candidates ──
    final sfUcis = discovery.lines
        .map((l) => l.moveUci)
        .where((u) => u.isNotEmpty)
        .toList();

    final candidates = _filterCandidates(sfUcis, _maiaProbs!, dbData);
    _selectedMoveUcis = candidates;

    _perfLog('Filtered ${candidates.length} candidates '
        '(${sfUcis.length} SF + '
        '${candidates.length - sfUcis.length} Maia/DB)');

    // ── Fire-and-forget: cumulative probability ──
    if (useDb) _calculateCumulativeProbability();

    // ── Start evaluation phase ──
    _pool.startEvaluation(
      baseFen: widget.fen,
      moveUcis: candidates,
      evalDepth: _settings.depth,
      easeDepth: _settings.easeDepth,
    );

    if (mounted) setState(() {});
  }

  /// Filter candidates: SF moves always included.
  /// Non-SF moves: include only if Maia >= 2% OR DB >= 2%.
  /// Capped at maxAnalysisMoves.
  List<String> _filterCandidates(
    List<String> sfUcis,
    Map<String, double> maiaProbs,
    PositionProbabilities? dbData,
  ) {
    final sfSet = sfUcis.toSet();
    final candidates = <String>[...sfUcis];
    final seen = Set<String>.from(sfUcis);

    // Collect non-SF candidates from Maia and DB
    final nonSfCandidates = <String>{};
    for (final uci in maiaProbs.keys) {
      if (!sfSet.contains(uci)) nonSfCandidates.add(uci);
    }
    if (dbData != null) {
      for (final m in dbData.moves) {
        if (m.uci.isNotEmpty && !sfSet.contains(m.uci)) {
          nonSfCandidates.add(m.uci);
        }
      }
    }

    // Score and sort non-SF candidates by max(maia, db) descending
    final scored = <MapEntry<String, double>>[];
    for (final uci in nonSfCandidates) {
      if (seen.contains(uci)) continue;
      final maiaP = maiaProbs[uci] ?? 0.0;
      double dbP = 0.0;
      if (dbData != null) {
        for (final m in dbData.moves) {
          if (m.uci == uci) {
            dbP = m.probability;
            break;
          }
        }
      }

      // Both Maia AND DB < 2% → skip
      if (maiaP < 0.02 && dbP < 2.0) continue;

      final score = math.max(maiaP * 100, dbP);
      scored.add(MapEntry(uci, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));

    final extraSlots = _settings.maxAnalysisMoves - candidates.length;
    for (int i = 0; i < scored.length && i < extraSlots; i++) {
      candidates.add(scored[i].key);
    }

    return candidates;
  }

  // ── Source helpers ──────────────────────────────────────────────────────

  Future<Map<String, double>> _runMaiaAnalysis() async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      return {};
    }
    _perfLog('Maia inference START');
    try {
      final probs =
          await MaiaFactory.instance!.evaluate(widget.fen, _settings.maiaElo);
      _perfLog('Maia inference DONE — ${probs.length} moves');
      return probs;
    } catch (e) {
      _perfLog('Maia FAILED — $e');
      return {};
    }
  }

  Future<void> _fetchDbData() async {
    _perfLog('DB fetch START');
    try {
      await _probabilityService.fetchProbabilities(widget.fen);
      _perfLog('DB fetch DONE — '
          '${_probabilityService.currentPosition.value?.moves.length ?? 0} moves');
    } catch (e) {
      if (kDebugMode) print('[Engine] DB FAILED — $e');
    }
  }

  Future<void> _calculateCumulativeProbability() async {
    if (widget.currentMoveSequence.isEmpty) {
      _probabilityService.cumulativeProbability.value = 100.0;
      return;
    }
    try {
      await _probabilityService.calculateCumulativeProbability(
        widget.currentMoveSequence,
        isUserWhite: widget.isWhiteRepertoire,
        startingMoves: _settings.probabilityStartMoves,
      );
    } catch (e) {
      if (kDebugMode) print('[Engine] Cumulative DB FAILED — $e');
    }
  }

  // ── Cache ──────────────────────────────────────────────────────────────

  void _restoreFromCache(_PositionSnapshot cached) {
    _selectedMoveUcis = List.from(cached.selectedMoveUcis);
    _maiaProbs = Map.from(cached.maiaProbs);
    _pool.results.value = Map.from(cached.poolResults);
    _pool.discoveryResult.value = cached.discoveryResult;

    _pool.poolStatus.value = PoolStatus(
      phase: 'complete',
      totalMoves: cached.selectedMoveUcis.length,
      completedMoves: cached.poolResults.length,
    );

    if (_settings.showProbability) {
      _calculateCumulativeProbability();
    }

    setState(() {});
  }

  void _trySaveCurrentToCache() {
    if (_selectedMoveUcis.isEmpty || _maiaProbs == null) return;
    if (!_pool.poolStatus.value.isComplete) return;

    final fen = _currentAnalysisFen;
    if (fen == null) return;
    _analysisCache[fen] = _PositionSnapshot(
      selectedMoveUcis: List.from(_selectedMoveUcis),
      maiaProbs: Map.from(_maiaProbs!),
      poolResults: Map.from(_pool.results.value),
      discoveryResult: _pool.discoveryResult.value,
    );

    while (_analysisCache.length > _maxCacheSize) {
      _analysisCache.remove(_analysisCache.keys.first);
    }
  }

  void _onPoolStatusChanged() {
    final ps = _pool.poolStatus.value;
    if (ps.isComplete) {
      final res = _pool.results.value;
      final withEase = res.values.where((r) => r.moveEase != null).length;
      _perfLog('Evaluation COMPLETE — ${res.length} evals, '
          '$withEase with ease — FULL PIPELINE DONE');
      if (kDebugMode) {
        for (final e in res.entries) {
          final r = e.value;
          final easeStr = r.moveEase != null
              ? r.moveEase!.toStringAsFixed(3)
              : 'null';
          print('[Engine]   ${uciToSan(widget.fen, e.key)}: '
              'cp=${r.scoreCp}, mate=${r.scoreMate}, '
              'ease=$easeStr');
        }
      }
      _trySaveCurrentToCache();
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  void _toggleEngine(bool value) {
    setState(() {
      _engineEnabled = value;
    });
    if (_isActive) {
      // Turning on — kick off analysis for the current position.
      _runAnalysis();
    } else {
      // Turning off — cancel any in-progress work.
      _pool.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return const Center(child: Text('Analysis paused'));
    }

    return Column(
      children: [
        _buildSettingsBar(),
        const Divider(height: 1),
        if (_engineEnabled) ...[
          Expanded(child: _buildUnifiedMoveTable()),
          EnginePaneFooter(
            settings: _settings,
            pool: _pool,
            probabilityService: _probabilityService,
            fen: widget.fen,
            maiaProbs: _maiaProbs,
            isWhiteRepertoire: widget.isWhiteRepertoire,
          ),
        ] else
          const Expanded(
            child: Center(
              child: Text(
                'Engine off',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSettingsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          // ── On/off toggle ──
          SizedBox(
            height: 24,
            child: FittedBox(
              child: Switch(
                value: _engineEnabled,
                onChanged: _toggleEngine,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // ── Status text ──
          Expanded(
            child: _engineEnabled
                ? ListenableBuilder(
                    listenable: _pool.poolStatus,
                    builder: (context, _) {
                      final ps = _pool.poolStatus.value;

                      if (ps.isDiscovering) {
                        return Text(
                          'Depth ${ps.discoveryDepth} • '
                          '${formatNodes(ps.discoveryNodes)} nodes • '
                          '${formatNps(ps.discoveryNps)} n/s',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[400]),
                          overflow: TextOverflow.ellipsis,
                        );
                      }

                      if (ps.isEvaluating) {
                        final sans = ps.evaluatingUcis
                            .map((u) => uciToSan(widget.fen, u))
                            .join(', ');
                        final totalRam =
                            ps.hashPerWorkerMb * ps.activeWorkers;
                        return Text(
                          'Evaluating ${ps.completedMoves}/${ps.totalMoves}: '
                          '$sans  |  '
                          'Workers: ${ps.activeWorkers}  |  '
                          '${formatRam(totalRam)}',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[400]),
                          overflow: TextOverflow.ellipsis,
                        );
                      }

                      if (ps.isComplete) {
                        return Text(
                          '${ps.totalMoves} moves analyzed',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[400]),
                        );
                      }

                      return Text(
                        'Initializing...',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[400]),
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  )
                : Text(
                    'Engine off',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: 'Engine Settings',
            onPressed: () => showEngineSettingsDialog(
              context: context,
              settings: _settings,
              currentProbabilityStartMoves: _settings.probabilityStartMoves,
              onProbabilityStartMovesChanged: (newVal) {
                _settings.probabilityStartMoves = newVal;
                _calculateCumulativeProbability();
              },
            ),
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
        _pool.discoveryResult,
        _pool.results,
        _pool.poolStatus,
        _probabilityService.currentPosition,
      ]),
      builder: (context, _) {
        final ps = _pool.poolStatus.value;

        // Show loading if nothing is ready yet
        if (ps.isIdle &&
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
        ? ' (${formatCount(dbData.totalGames)})'
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
                    'Ease from your perspective\n'
                    'Higher = better for you',
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

    final continuation = formatContinuation(widget.fen, move.fullPv);

    // Ease from the player's perspective (higher = better for the player).
    // When the player moves, resulting position has the *opponent* to move,
    // so invert: 1 − ease (opponent difficulty).
    // When the opponent moves, resulting position has the *player* to move,
    // so use ease directly (player navigability).
    final fenParts = widget.fen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';
    final isPlayerTurn = (isWhiteToMove == widget.isWhiteRepertoire);
    final displayEase = move.moveEase != null
        ? (isPlayerTurn ? 1.0 - move.moveEase! : move.moveEase!)
        : null;

    return InkWell(
      onTap: () => widget.onMoveSelected?.call(move.uci),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
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
            if (_settings.showEase)
              SizedBox(
                width: 46,
                child: Text(
                  displayEase != null
                      ? displayEase.toStringAsFixed(2)
                      : '--',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        displayEase != null ? FontWeight.w500 : FontWeight.normal,
                    color: displayEase != null
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

  // ─── Merge Logic ────────────────────────────────────────────────────────

  List<_MergedMove> _mergeMoves() {
    final byUci = <String, _MergedMove>{};
    final discovery = _pool.discoveryResult.value;

    if (_selectedMoveUcis.isEmpty) {
      // Discovery phase — show progressive SF lines
      for (final line in discovery.lines) {
        if (line.pv.isEmpty) continue;
        final uci = line.pv.first;
        final m = byUci.putIfAbsent(uci, () => _MergedMove(uci: uci));
        m.stockfishCp = line.scoreCp;
        m.stockfishMate = line.scoreMate;
        m.fullPv = line.pv;
        m.stockfishRank = line.pvNumber;
      }
    } else {
      // Post-filtering — show curated selection
      for (final uci in _selectedMoveUcis) {
        byUci[uci] = _MergedMove(uci: uci);
      }
      // Fill discovery data for SF-ranked moves
      for (final line in discovery.lines) {
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

    // ── Fill ALL columns from ALL sources ──
    final poolResults = _pool.results.value;
    final dbData = _probabilityService.currentPosition.value;

    for (final m in byUci.values) {
      // Pool results: eval + ease (overrides discovery eval with deeper per-move eval)
      final poolResult = poolResults[m.uci];
      if (poolResult != null) {
        if (poolResult.hasEval) {
          m.stockfishCp = poolResult.scoreCp;
          m.stockfishMate = poolResult.scoreMate;
          if (poolResult.pv.isNotEmpty) m.fullPv = poolResult.pv;
        }
        if (poolResult.moveEase != null) {
          m.moveEase = poolResult.moveEase;
        }
      }

      // Maia
      if (m.maiaProb == null && _maiaProbs != null) {
        m.maiaProb = _maiaProbs![m.uci] ?? 0.0;
      }

      // DB
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

      if (m.san.isEmpty) {
        m.san = uciToSan(widget.fen, m.uci);
      }
    }

    // ── Sort: SF-ranked first (by rank), then others by eval ──
    final sfMoves = byUci.values.where((m) => m.stockfishRank != null).toList()
      ..sort((a, b) => a.stockfishRank!.compareTo(b.stockfishRank!));
    final sfUcis = sfMoves.map((m) => m.uci).toSet();

    final others = byUci.values.where((m) => !sfUcis.contains(m.uci)).toList()
      ..sort((a, b) {
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

    return [...sfMoves, ...others];
  }
}
