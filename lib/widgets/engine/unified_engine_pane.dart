/// Unified Engine Pane - Single table combining Stockfish, Maia, and Probability
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../models/merged_move.dart';
import 'engine_move_row.dart';
import '../../services/analysis_service.dart';
import '../../services/engine/engine_lifecycle.dart';
import '../../services/eval_cache.dart';
import 'engine_gate.dart';
import '../../services/maia_factory.dart';
import '../../services/probability_service.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart';
import 'engine_pane_footer.dart';
import '../analysis/analysis_settings_sheet.dart';
import 'floating_board_preview.dart';
import 'package:chess_auto_prep/utils/log.dart';

/// Lightweight stopwatch helper for timestamped performance logging.
Stopwatch? _perfWatch;
void _perfLog(String msg) {
  if (!kDebugMode) return;
  _perfWatch ??= Stopwatch();
  final ms = _perfWatch!.elapsedMilliseconds;
  log.i('[Perf ${ms.toString().padLeft(6)}ms] $msg');
}

void _perfReset() {
  _perfWatch = Stopwatch()..start();
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
  final EngineSettings _settings = EngineSettings.instance;
  final AnalysisService _analysis = AnalysisService.instance;
  final ProbabilityService _probabilityService = ProbabilityService.instance;
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

  /// Whether analysis should run right now. Generation owns the engine, so
  /// the pane goes dormant (and shows [EngineBusyNotice]) while it runs.
  bool get _isActive =>
      widget.isActive &&
      EngineLifecycle.instance.state != EngineState.off &&
      !EngineGate.isLocked;

  bool get _engineEnabled => EngineLifecycle.instance.state != EngineState.off;

  @override
  void initState() {
    super.initState();
    _analysisConfigRevision = _settings.analysisConfigRevision;
    // Manual listener: analysisConfigRevision changes trigger re-analysis, not just rebuild.
    _settings.addListener(_onSettingsChanged);
    _analysis.poolStatus.addListener(_onPoolStatusChanged);
    EngineLifecycle.instance.addListener(_onLifecycleChanged);
    _lastLifecycleState = EngineLifecycle.instance.state;

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

    if (fenChanged || becameActive) {
      _scheduleAnalysis();
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

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _analysis.poolStatus.removeListener(_onPoolStatusChanged);
    EngineLifecycle.instance.removeListener(_onLifecycleChanged);
    _analysis.cancel();
    super.dispose();
  }

  void _onLifecycleChanged() {
    if (!mounted) return;
    final state = EngineLifecycle.instance.state;
    final prev = _lastLifecycleState;
    _lastLifecycleState = state;

    if (!_isActive) {
      if (prev != state) _analysis.cancel();
      _scheduleSetState();
      return;
    }

    // Restart only when engine becomes usable again (toggle on / exit generation),
    // not when analysis finishes (analyzing → idle) or we enter analyzing.
    final becameUsable =
        (prev == null ||
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
      log.i('[Engine] ── _runAnalysis() for $shortFen ──');
    }

    EngineLifecycle.instance.onPositionChanged(widget.fen);
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
    final useMaia =
        _settings.showMaia &&
        _settings.fetchMaiaForOpponent &&
        MaiaFactory.isAvailable &&
        MaiaFactory.instance != null;

    _perfLog(
      'Pipeline START — SF=${useStockfish ? "ON" : "OFF"}, '
      'Maia=${useMaia ? "ON" : "OFF"}, DB=OFF',
    );

    try {
      // ── Fire all sources in parallel ──
      final discoveryFuture = useStockfish
          ? _analysis.runDiscovery(
              fen: widget.fen,
              depth: _settings.depth,
              multiPv: _settings.multiPv,
            )
          : Future.value(const DiscoveryResult());

      final maiaFuture = useMaia
          ? _runMaiaAnalysis()
          : Future.value(<String, double>{});

      // ── Await all ──
      final results = await Future.wait<Object?>([discoveryFuture, maiaFuture]);

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

      _perfLog(
        'Filtered ${candidates.length} candidates '
        '(${sfUcis.length} SF + '
        '${candidates.length - sfUcis.length} Maia/DB)',
      );

      // ── Start evaluation phase ──
      _analysis.startEvaluation(
        baseFen: widget.fen,
        moveUcis: candidates,
        evalDepth: _settings.depth,
      );

      _scheduleSetState();
    } catch (e) {
      _analysis.endEnginePaneAnalysis(widget.fen);
      if (kDebugMode) log.e('[Engine] Pipeline FAILED — $e');
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
      final result = await MaiaFactory.instance!.evaluate(
        widget.fen,
        _settings.maiaElo,
      );
      _perfLog('Maia inference DONE — ${result.policy.length} moves');
      return result.policy;
    } catch (e) {
      _perfLog('Maia FAILED — $e');
      return {};
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
        EngineLifecycle.instance.onAnalysisComplete();
        _analysis.endEnginePaneAnalysis(_currentAnalysisFen);
        _perfLog(
          'Evaluation COMPLETE — ${_analysis.results.value.length} evals',
        );
        _trySaveCurrentToCache();
      }
    });
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!widget.compact) ...[_buildSettingsBar(), const Divider(height: 1)],
        if (EngineGate.isLocked)
          const Expanded(child: EngineBusyNotice())
        else if (_engineEnabled) ...[
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
            child: _engineEnabled && !EngineGate.isLocked
                ? ListenableBuilder(
                    listenable: _analysis.poolStatus,
                    builder: (context, _) {
                      final ps = _analysis.poolStatus.value;

                      if (ps.isDiscovering) {
                        return Text(
                          'Depth ${ps.discoveryDepth} • '
                          '${formatNodes(ps.discoveryNodes)} nodes • '
                          '${formatNps(ps.discoveryNps)} n/s',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[400],
                          ),
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
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[400],
                          ),
                          overflow: TextOverflow.ellipsis,
                        );
                      }

                      if (ps.isComplete) {
                        return Text(
                          '${ps.totalMoves} moves analyzed',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[400],
                          ),
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
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 13,
                          ),
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
        color: muted
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.transparent,
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

  Widget _buildMoveRow(MergedMove move) {
    return EngineMoveRow(
      move: move,
      settings: _settings,
      fen: widget.fen,
      boardPreview: widget.boardPreview,
      onMoveSelected: widget.onMoveSelected,
      onLineMoveTapped: widget.onLineMoveTapped,
      previewStackKey: _previewStackKey,
    );
  }

  // ─── Merge Logic ──────────────────────────────────

  List<MergedMove> _mergeMoves() {
    final byUci = <String, MergedMove>{};
    final discovery = _analysis.discoveryResult.value;

    if (_selectedMoveUcis.isEmpty) {
      for (final line in discovery.lines) {
        if (line.pv.isEmpty) continue;
        final uci = line.pv.first;
        final m = byUci.putIfAbsent(uci, () => MergedMove(uci: uci));
        m.stockfishCp = line.scoreCp;
        m.stockfishMate = line.scoreMate;
        m.fullPv = line.pv;
        m.stockfishRank = line.pvNumber;
      }
    } else {
      for (final uci in _selectedMoveUcis) {
        byUci[uci] = MergedMove(uci: uci);
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
