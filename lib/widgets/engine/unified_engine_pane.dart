/// Unified Engine Pane - Single table combining Stockfish, Maia, and Probability
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/analysis_service.dart';
import '../../services/engine/engine_lifecycle.dart';
import '../../services/eval_cache.dart';
import '../../services/maia_factory.dart';
import '../../services/probability_service.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart';
import '../../utils/fen_utils.dart';
import '../../utils/eval_constants.dart';
import 'engine_pane_footer.dart';
import '../analysis/analysis_settings_sheet.dart';
import 'floating_board_preview.dart';
import '../clickable_move_line.dart';

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
  double? maiaProb; // 0.0 – 1.0
  double? dbProb; // 0 – 100 (percentage)
  int? stockfishRank; // 1-based rank from Stockfish MultiPV

  _MergedMove({required this.uci});

  String get evalString =>
      formatEvalDisplay(scoreCp: stockfishCp, scoreMate: stockfishMate);

  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: stockfishCp, scoreMate: stockfishMate);

  bool get hasStockfish => stockfishCp != null || stockfishMate != null;
}

class UnifiedEnginePane extends StatefulWidget {
  final String fen;
  final bool isActive;
  final bool? isUserTurn;
  final Function(String uciMove)? onMoveSelected;
  final void Function(List<String> sanMoves, int clickedIndex)?
      onLineMoveTapped;
  final List<String> currentMoveSequence;
  final bool isWhiteRepertoire;
  final VoidCallback? onSetRoot;
  final BoardPreviewController? boardPreview;

  /// Hides the inline settings bar; use [onOpenSettings] from parent instead.
  final bool compact;

  final VoidCallback? onOpenSettings;

  const UnifiedEnginePane({
    super.key,
    required this.fen,
    this.isActive = true,
    this.isUserTurn,
    this.onMoveSelected,
    this.onLineMoveTapped,
    this.currentMoveSequence = const [],
    this.isWhiteRepertoire = true,
    this.onSetRoot,
    this.boardPreview,
    this.compact = false,
    this.onOpenSettings,
  });

  @override
  State<UnifiedEnginePane> createState() => _UnifiedEnginePaneState();
}

/// Cached snapshot of a completed analysis for a single FEN.
///
/// Bundles ALL per-position data atomically so restoring from cache
/// never leaves any source stale (Stockfish, Maia, DB, cumulative).
class _PositionSnapshot {
  final List<String> selectedMoveUcis;
  final Map<String, double> maiaProbs;
  final Map<String, MoveAnalysisResult> poolResults;
  final DiscoveryResult discoveryResult;
  final ExplorerResponse? dbResponse;

  _PositionSnapshot({
    required this.selectedMoveUcis,
    required this.maiaProbs,
    required this.poolResults,
    required this.discoveryResult,
    required this.dbResponse,
  });
}

class _UnifiedEnginePaneState extends State<UnifiedEnginePane> {
  final EngineSettings _settings = EngineSettings();
  final AnalysisService _analysis = AnalysisService();
  final ProbabilityService _probabilityService = ProbabilityService();
  final GlobalKey _previewStackKey = GlobalKey();

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

  int _analysisConfigRevision = 0;

  EngineState? _lastLifecycleState;
  bool _analysisScheduled = false;

  /// Whether analysis should run right now.
  bool get _isActive =>
      widget.isActive && EngineLifecycle().state != EngineState.off;

  bool get _engineEnabled => EngineLifecycle().state != EngineState.off;

  @override
  void initState() {
    super.initState();
    _analysisConfigRevision = _settings.analysisConfigRevision;
    // Manual listener: analysisConfigRevision changes trigger re-analysis, not just rebuild.
    _settings.addListener(_onSettingsChanged);
    _analysis.poolStatus.addListener(_onPoolStatusChanged);
    EngineLifecycle().addListener(_onLifecycleChanged);
    _lastLifecycleState = EngineLifecycle().state;

    if (_isActive) {
      _analysis.beginEnginePaneAnalysis(widget.fen);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startInitialAnalysis();
      });
    }
  }

  @override
  void didUpdateWidget(UnifiedEnginePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isActive) return;

    final fenChanged = widget.fen != oldWidget.fen;
    final becameActive = !oldWidget.isActive;
    final moveSeqChanged =
        !_listEquals(widget.currentMoveSequence, oldWidget.currentMoveSequence);

    if (fenChanged || becameActive) {
      _scheduleAnalysis();
    } else if (moveSeqChanged && _settings.showProbability) {
      _scheduleCumulativeProbability();
    }
  }

  void _scheduleAnalysis() {
    if (_analysisScheduled) return;
    _analysisScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _analysisScheduled = false;
      if (!mounted || !_isActive) return;
      _runAnalysis();
    });
  }

  void _scheduleSetState() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _scheduleCumulativeProbability() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isActive) return;
      _calculateCumulativeProbability();
    });
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _analysis.poolStatus.removeListener(_onPoolStatusChanged);
    EngineLifecycle().removeListener(_onLifecycleChanged);
    _analysis.cancel();
    super.dispose();
  }

  void _onLifecycleChanged() {
    if (!mounted) return;
    final state = EngineLifecycle().state;
    final prev = _lastLifecycleState;
    _lastLifecycleState = state;

    if (!_isActive) {
      if (prev != state) _analysis.cancel();
      _scheduleSetState();
      return;
    }

    // Restart only when engine becomes usable again (toggle on / exit generation),
    // not when analysis finishes (analyzing → idle) or we enter analyzing.
    final becameUsable = (prev == null ||
            prev == EngineState.off ||
            prev == EngineState.generating) &&
        (state == EngineState.idle || state == EngineState.analyzing) &&
        !(prev == null && state == EngineState.analyzing);
    if (becameUsable) {
      _scheduleAnalysis();
    }
    _scheduleSetState();
  }

  void _onSettingsChanged() {
    final revision = _settings.analysisConfigRevision;
    final configChanged = revision != _analysisConfigRevision;
    if (configChanged) {
      _analysisConfigRevision = revision;
      _analysisCache.remove(widget.fen);
      if (_isActive) {
        _scheduleAnalysis();
      }
    }
    _scheduleSetState();
  }

  void _runAnalysis() {
    if (kDebugMode) {
      final shortFen = widget.fen.split(' ').take(2).join(' ');
      print('[Engine] ── _runAnalysis() for $shortFen ──');
    }

    EngineLifecycle().onPositionChanged(widget.fen);
    _trySaveCurrentToCache();
    _analysis.beginEnginePaneAnalysis(widget.fen);
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
        _settings.fetchMaiaForOpponent &&
        MaiaFactory.isAvailable &&
        MaiaFactory.instance != null;

    _perfLog('Pipeline START — SF=${useStockfish ? "ON" : "OFF"}, '
        'Maia=${useMaia ? "ON" : "OFF"}, DB=OFF');

    try {
      // ── Fire all sources in parallel ──
      final discoveryFuture = useStockfish
          ? _analysis.runDiscovery(
              fen: widget.fen,
              depth: _settings.depth,
              multiPv: _settings.multiPv,
            )
          : Future.value(const DiscoveryResult());

      final maiaFuture =
          useMaia ? _runMaiaAnalysis() : Future.value(<String, double>{});

      // ── Await all ──
      final results = await Future.wait<Object?>([
        discoveryFuture,
        maiaFuture,
      ]);

      if (!mounted || _analysisGeneration != myGen) {
        _analysis.endEnginePaneAnalysis(widget.fen);
        return;
      }

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

      // ── Start evaluation phase ──
      _analysis.startEvaluation(
        baseFen: widget.fen,
        moveUcis: candidates,
        evalDepth: _settings.depth,
      );

      _scheduleSetState();
    } catch (e) {
      _analysis.endEnginePaneAnalysis(widget.fen);
      if (kDebugMode) print('[Engine] Pipeline FAILED — $e');
      rethrow;
    }
  }

  /// Filter candidates: SF moves always included.
  /// Non-SF moves: include only if Maia >= 2% OR DB >= 2%.
  /// Capped at maxAnalysisMoves.
  List<String> _filterCandidates(
    List<String> sfUcis,
    Map<String, double> maiaProbs,
    ExplorerResponse? dbData,
  ) {
    final sfSet = sfUcis.toSet();
    final candidates = <String>[...sfUcis];
    final seen = Set<String>.from(sfUcis);

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

    final scored = <MapEntry<String, double>>[];
    for (final uci in nonSfCandidates) {
      if (seen.contains(uci)) continue;
      final maiaP = maiaProbs[uci] ?? 0.0;
      double dbP = 0.0;
      if (dbData != null) {
        for (final m in dbData.moves) {
          if (m.uci == uci) {
            dbP = m.playRate;
            break;
          }
        }
      }

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
      final result =
          await MaiaFactory.instance!.evaluate(widget.fen, _settings.maiaElo);
      _perfLog('Maia inference DONE — ${result.policy.length} moves');
      return result.policy;
    } catch (e) {
      _perfLog('Maia FAILED — $e');
      return {};
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _selectedMoveUcis = List.from(cached.selectedMoveUcis);
      _maiaProbs = Map.from(cached.maiaProbs);
      _analysis.results.value = Map.from(cached.poolResults);
      _analysis.discoveryResult.value = cached.discoveryResult;

      // Restore DB data so the merge table shows correct play rates.
      _probabilityService.currentPosition.value = cached.dbResponse;

      _analysis.poolStatus.value = PoolStatus(
        phase: 'complete',
        totalMoves: cached.selectedMoveUcis.length,
        completedMoves: cached.poolResults.length,
      );

      if (_settings.showProbability) {
        _calculateCumulativeProbability();
      }

      _scheduleSetState();
    });
  }

  void _trySaveCurrentToCache() {
    if (_selectedMoveUcis.isEmpty || _maiaProbs == null) return;
    if (!_analysis.poolStatus.value.isComplete) return;

    final fen = _currentAnalysisFen;
    if (fen == null) return;
    _analysisCache[fen] = _PositionSnapshot(
      selectedMoveUcis: List.from(_selectedMoveUcis),
      maiaProbs: Map.from(_maiaProbs!),
      poolResults: Map.from(_analysis.results.value),
      discoveryResult: _analysis.discoveryResult.value,
      dbResponse: _probabilityService.currentPosition.value,
    );

    while (_analysisCache.length > _maxCacheSize) {
      _analysisCache.remove(_analysisCache.keys.first);
    }

    _persistBestEvalToCache(fen);
  }

  void _persistBestEvalToCache(String fen) {
    final discovery = _analysis.discoveryResult.value;
    if (discovery.lines.isEmpty) return;
    final best = discovery.lines.first;
    final cp = best.scoreCp;
    if (cp == null) return;
    EvalCache.instance.putEvalCpWhite(fen, cp, best.depth);
  }

  void _onPoolStatusChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ps = _analysis.poolStatus.value;
      if (ps.isComplete) {
        EngineLifecycle().onAnalysisComplete();
        _analysis.endEnginePaneAnalysis(_currentAnalysisFen);
        _perfLog(
            'Evaluation COMPLETE — ${_analysis.results.value.length} evals');
        _trySaveCurrentToCache();
      }
    });
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!widget.compact) ...[
          _buildSettingsBar(),
          const Divider(height: 1),
        ],
        if (_engineEnabled) ...[
          Expanded(child: _buildUnifiedMoveTable()),
          EnginePaneFooter(
            settings: _settings,
            analysis: _analysis,
            probabilityService: _probabilityService,
            fen: widget.fen,
            maiaProbs: _maiaProbs,
            isWhiteRepertoire: widget.isWhiteRepertoire,
            onSetRoot: widget.onSetRoot,
          ),
        ] else
          const Expanded(child: SizedBox.shrink()),
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
            child: _engineEnabled
                ? ListenableBuilder(
                    listenable: _analysis.poolStatus,
                    builder: (context, _) {
                      final ps = _analysis.poolStatus.value;

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
                        return Text(
                          'Evaluating ${ps.completedMoves}/${ps.totalMoves}: '
                          '$sans  |  '
                          'Workers: ${ps.activeWorkers}',
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
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: 'Engine Settings',
            onPressed: () {
              if (widget.onOpenSettings != null) {
                widget.onOpenSettings!();
              } else {
                showAnalysisSettingsSheet(context);
              }
            },
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
        _settings,
        _analysis.discoveryResult,
        _analysis.results,
        _analysis.poolStatus,
        _probabilityService.currentPosition,
      ]),
      builder: (context, _) {
        final moves = _mergeMoves();

        return Stack(
          key: _previewStackKey,
          clipBehavior: Clip.none,
          children: [
            ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              children: [
                _buildTableHeader(),
                const Divider(height: 1),
                if (moves.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Analyzing...',
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 13),
                        ),
                      ],
                    ),
                  )
                else
                  ...moves.map(_buildMoveRow),
              ],
            ),
            if (widget.boardPreview != null)
              FloatingBoardPreview(
                stackKey: _previewStackKey,
                controller: widget.boardPreview!,
                flipped: !widget.isWhiteRepertoire,
                ownerTag: _previewStackKey,
              ),
          ],
        );
      },
    );
  }

  static const _colHeaderTip =
      'Tap to dim this column; tap again to restore full color.';

  Widget _buildColumnHeader({
    required String columnId,
    required String label,
    required TextAlign textAlign,
    double? width,
    Widget? leading,
    String? tooltipExtra,
  }) {
    final muted = _settings.isAnalysisColumnMuted(columnId);
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: muted ? AppColors.onSurfaceDim : Colors.grey[400],
      letterSpacing: 0.5,
      decoration: muted ? TextDecoration.lineThrough : null,
      decorationColor: AppColors.onSurfaceDim,
    );

    final child = Row(
      mainAxisAlignment: textAlign == TextAlign.right
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 2)],
        Text(
          label,
          style: style,
          textAlign: textAlign,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    final header = Tooltip(
      message: tooltipExtra != null
          ? '$tooltipExtra\n$_colHeaderTip'
          : _colHeaderTip,
      child: Material(
        color:
            muted ? Colors.white.withValues(alpha: 0.04) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: () {
            final id = columnId;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _settings.toggleAnalysisColumnMuted(id);
            });
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: child,
          ),
        ),
      ),
    );

    if (width != null) {
      return SizedBox(width: width, child: header);
    }
    return Expanded(child: header);
  }

  static const _narrowTableWidth = 200;

  Widget _buildTableHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowTableWidth;
        final showMaia =
            !narrow && _settings.showMaia && _settings.fetchMaiaForOpponent;
        final moveWidth = narrow ? 36.0 : 52.0;
        final evalWidth = narrow ? 44.0 : 58.0;
        final hPad = narrow ? 4.0 : 12.0;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: moveWidth,
                child: Text(
                  'MOVE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[500],
                    letterSpacing: 0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildColumnHeader(
                columnId: EngineSettings.colEval,
                label: 'EVAL',
                textAlign: TextAlign.center,
                width: evalWidth,
                tooltipExtra: 'Stockfish evaluation',
              ),
              if (!narrow) const SizedBox(width: 8),
              _buildColumnHeader(
                columnId: EngineSettings.colLine,
                label: 'LINE',
                textAlign: TextAlign.left,
                tooltipExtra: 'Principal variation continuation',
              ),
              if (showMaia)
                _buildColumnHeader(
                  columnId: EngineSettings.colMaia,
                  label: 'MAIA',
                  textAlign: TextAlign.right,
                  width: 46,
                  tooltipExtra: 'Maia ${_settings.maiaElo} prediction',
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMoveRow(_MergedMove move) {
    final evalMuted = _settings.isAnalysisColumnMuted(EngineSettings.colEval);
    final lineMuted = _settings.isAnalysisColumnMuted(EngineSettings.colLine);
    final maiaMuted = _settings.isAnalysisColumnMuted(EngineSettings.colMaia);

    final evalColor = move.hasStockfish
        ? AppColors.cpEval(move.effectiveCp, muted: evalMuted)
        : AppColors.onSurfaceDim;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowTableWidth;
        final showMaia =
            !narrow && _settings.showMaia && _settings.fetchMaiaForOpponent;
        final moveWidth = narrow ? 36.0 : 52.0;
        final evalWidth = narrow ? 44.0 : 58.0;
        final hPad = narrow ? 4.0 : 12.0;

        return InkWell(
          onTap: () => widget.onMoveSelected?.call(move.uci),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 6),
            child: Row(
              children: [
                Builder(
                  builder: (anchorContext) {
                    return MouseRegion(
                      onEnter: widget.boardPreview != null
                          ? (_) {
                              final box = anchorContext.findRenderObject()
                                  as RenderBox?;
                              if (box == null) return;
                              final anchor = box.localToGlobal(
                                Offset(box.size.width / 2, box.size.height),
                              );
                              _previewEngineMove(move, anchor);
                            }
                          : null,
                      onExit: widget.boardPreview != null
                          ? (_) => widget.boardPreview!.clearPreview()
                          : null,
                      child: SizedBox(
                        width: moveWidth,
                        child: Text(
                          move.san,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  },
                ),
                Container(
                  width: evalWidth,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: move.hasStockfish
                        ? AppColors.cpEvalBg(move.effectiveCp, muted: evalMuted)
                            .withValues(alpha: evalMuted ? 0.5 : 0.85)
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
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!narrow) const SizedBox(width: 8),
                Expanded(
                  child: _buildContinuationWidget(move, muted: lineMuted),
                ),
                if (showMaia)
                  SizedBox(
                    width: narrow ? 40 : 46,
                    child: Text(
                      move.maiaProb != null
                          ? '${(move.maiaProb! * 100).toStringAsFixed(0)}%'
                          : '--',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 14,
                        color: move.maiaProb != null
                            ? AppColors.maiaColor(muted: maiaMuted)
                            : AppColors.onSurfaceDim,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContinuationWidget(_MergedMove move, {bool muted = false}) {
    final lineColor = muted ? AppColors.onSurfaceDim : Colors.grey[500];
    if (move.fullPv.length <= 1 || widget.boardPreview == null) {
      final continuation = formatContinuation(widget.fen, move.fullPv);
      return Text(
        continuation,
        style: TextStyle(
          fontSize: 13,
          color: lineColor,
          fontFamily: 'monospace',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final afterFirstMove = playUciMove(widget.fen, move.uci);
    if (afterFirstMove == null) return const SizedBox.shrink();

    final continuationUci = move.fullPv.sublist(1);
    final sanMoves = uciPvToSan(afterFirstMove, continuationUci,
        maxMoves: continuationUci.length);
    if (sanMoves.isEmpty) return const SizedBox.shrink();

    final fenParts = afterFirstMove.split(' ');
    final fullMoveNumber =
        int.tryParse(fenParts.length >= 6 ? fenParts[5] : '1') ?? 1;
    final isBlack = !isWhiteToMove(afterFirstMove);
    final startPly = (fullMoveNumber - 1) * 2 + (isBlack ? 1 : 0);

    return ClickableMoveLineWidget(
      sanMoves: sanMoves,
      startPly: startPly,
      maxMoves: 8,
      fontSize: 13,
      onMoveTapped: (idx) {
        if (widget.onLineMoveTapped != null) {
          final fullLine = [move.san, ...sanMoves];
          widget.onLineMoveTapped!(fullLine, idx + 1);
          widget.boardPreview?.clearPreview();
        } else if (idx < continuationUci.length) {
          widget.onMoveSelected?.call(move.uci);
        }
      },
      onMoveHovered: (idx, anchor) {
        final fen = fenAfterMoves(afterFirstMove, sanMoves, idx);
        final uci = idx < continuationUci.length ? continuationUci[idx] : null;
        widget.boardPreview!.setPreview(
          fen,
          moves: sanMoves.sublist(0, idx + 1),
          target: BoardPreviewTarget.floating,
          lastMoveUci: uci,
          anchorGlobal: anchor,
          ownerTag: _previewStackKey,
        );
      },
      onHoverExit: () => widget.boardPreview!.clearPreview(),
    );
  }

  // ─── Merge Logic ────────────────────────────────────────────────────────

  void _previewEngineMove(_MergedMove move, Offset anchorGlobal) {
    final fen = playUciMove(widget.fen, move.uci);
    if (fen == null) return;
    widget.boardPreview!.setPreview(
      fen,
      moves: [move.san],
      target: BoardPreviewTarget.floating,
      lastMoveUci: move.uci,
      anchorGlobal: anchorGlobal,
      ownerTag: _previewStackKey,
    );
  }

  List<_MergedMove> _mergeMoves() {
    final byUci = <String, _MergedMove>{};
    final discovery = _analysis.discoveryResult.value;

    if (_selectedMoveUcis.isEmpty) {
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
      for (final uci in _selectedMoveUcis) {
        byUci[uci] = _MergedMove(uci: uci);
      }
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

    final poolResults = _analysis.results.value;
    final dbData = _probabilityService.currentPosition.value;

    for (final m in byUci.values) {
      final poolResult = poolResults[m.uci];
      if (poolResult != null) {
        if (poolResult.hasEval) {
          m.stockfishCp = poolResult.scoreCp;
          m.stockfishMate = poolResult.scoreMate;
          if (poolResult.pv.isNotEmpty) m.fullPv = poolResult.pv;
        }
      }

      if (m.maiaProb == null && _maiaProbs != null) {
        m.maiaProb = _maiaProbs![m.uci] ?? 0.0;
      }

      if (m.dbProb == null && dbData != null) {
        double? found;
        for (final dbm in dbData.moves) {
          if (dbm.uci == m.uci) {
            found = dbm.playRate;
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
