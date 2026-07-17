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

part 'unified_engine_pane_analysis.dart';
part 'unified_engine_pane_table.dart';

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

// ── Per-FEN analysis cache (static — survives widget rebuilds) ──
final Map<String, _PositionSnapshot> _analysisCache = {};
const int _maxCacheSize = 50;

abstract class _UnifiedEnginePaneStateBase extends State<UnifiedEnginePane> {
  final EngineSettings _settings = EngineSettings.instance;
  final AnalysisService _analysis = AnalysisService.instance;
  final ProbabilityService _probabilityService = ProbabilityService.instance;
  final GlobalKey _previewStackKey = GlobalKey();

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
}

class _UnifiedEnginePaneState extends _UnifiedEnginePaneStateBase
    with _EnginePaneAnalysis, _EnginePaneTable {
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

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _analysis.poolStatus.removeListener(_onPoolStatusChanged);
    EngineLifecycle.instance.removeListener(_onLifecycleChanged);
    _analysis.cancel();
    super.dispose();
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
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.onSurfaceSoft,
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
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.onSurfaceSoft,
                          ),
                          overflow: TextOverflow.ellipsis,
                        );
                      }

                      if (ps.isComplete) {
                        return Text(
                          '${ps.totalMoves} moves analyzed',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.onSurfaceSoft,
                          ),
                        );
                      }

                      return const Text(
                        'Initializing...',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.onSurfaceSoft,
                        ),
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
}
