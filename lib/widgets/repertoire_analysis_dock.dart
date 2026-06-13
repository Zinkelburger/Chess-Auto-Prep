/// Side-by-side Stockfish + expectimax under the PGN editor.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/engine_settings.dart';
import '../services/analysis_service.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../services/coherence_service.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/expectimax_line_service.dart'
    show hasPrecomputedExpectimaxAtPly;
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/on_the_fly_expectimax_service.dart';
import '../theme/app_colors.dart';
import '../utils/chess_utils.dart' show formatEvalDisplay, uciToSan;
import '../utils/eval_constants.dart';
import 'analysis/analysis_settings_sheet.dart';
import 'engine/expectimax_panel_host.dart';
import 'engine/unified_engine_pane.dart';

/// Stockfish PV and expectimax PV shown together (split horizontally).
class RepertoireAnalysisDock extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isActive;
  final bool isGenerating;
  final bool isGenerationPaused;

  const RepertoireAnalysisDock({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    required this.isActive,
    this.isGenerating = false,
    this.isGenerationPaused = false,
  });

  @override
  State<RepertoireAnalysisDock> createState() => _RepertoireAnalysisDockState();
}

class _RepertoireAnalysisDockState extends State<RepertoireAnalysisDock> {
  final OnTheFlyExpectimaxService _onTheFly = OnTheFlyExpectimaxService();
  final EngineSettings _settings = EngineSettings();
  final AnalysisService _analysis = AnalysisService();
  bool _autoComputeScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleAutoCompute();
    widget.controller.addListener(_onControllerChanged);
    // Manual listener: may restart on-the-fly expectimax when dock/depth settings change.
    _settings.addListener(_onSettingsChanged);
    _analysis.discoveryResult.addListener(_onAnalysisUpdated);
    _onTheFly.addListener(_onAnalysisUpdated);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _settings.removeListener(_onSettingsChanged);
    _analysis.discoveryResult.removeListener(_onAnalysisUpdated);
    _onTheFly.removeListener(_onAnalysisUpdated);
    _onTheFly.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RepertoireAnalysisDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree != widget.tree ||
        oldWidget.treeConfig != widget.treeConfig ||
        oldWidget.isGenerating != widget.isGenerating ||
        oldWidget.isGenerationPaused != widget.isGenerationPaused) {
      _scheduleAutoCompute();
    }
  }

  void _onControllerChanged() => _scheduleAutoCompute();

  void _onSettingsChanged() {
    _scheduleAutoCompute();
    _scheduleSetState();
  }

  void _onAnalysisUpdated() => _scheduleSetState();

  void _scheduleAutoCompute() {
    if (_autoComputeScheduled) return;
    _autoComputeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoComputeScheduled = false;
      if (mounted) _maybeAutoCompute();
    });
  }

  void _scheduleSetState() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _maybeAutoCompute() {
    if (EngineLifecycle().state == EngineState.off ||
        EngineLifecycle().state == EngineState.generating) {
      return;
    }
    if (widget.isGenerating && !widget.isGenerationPaused) return;
    if (!_settings.showExpectimaxDock) return;

    final fen = widget.controller.fen;
    if (_onTheFly.currentFen == fen &&
        (_onTheFly.state == OnTheFlyState.computing ||
            (_onTheFly.state == OnTheFlyState.ready &&
                _onTheFly.progressiveLines.lines.isNotEmpty))) {
      return;
    }

    if (_hasPrecomputedExpectimax(fen)) return;

    _onTheFly.ensureRunning(
      fen: widget.controller.fen,
      playAsWhite: widget.controller.isRepertoireWhite,
      mainTree: widget.tree,
      mainConfig: widget.treeConfig,
      mainFenMap: widget.fenMap,
      maxDepth: _settings.onTheFlyMaxDepth,
    );
  }

  bool get _engineActive =>
      widget.isActive &&
      EngineLifecycle().state != EngineState.off &&
      EngineLifecycle().state != EngineState.generating &&
      (!widget.isGenerating || widget.isGenerationPaused);

  @override
  Widget build(BuildContext context) {
    final showEngine = _settings.showEngineDock;
    final showEx = _settings.showExpectimaxDock;

    if (!showEngine && !showEx) {
      return Center(
        child: TextButton.icon(
          onPressed: () => showAnalysisSettingsSheet(context),
          icon: const Icon(Icons.settings),
          label: const Text('Enable analysis panels'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSummaryBar(),
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(
          child: showEngine && showEx
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _buildEnginePane()),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: AppColors.divider,
                    ),
                    Expanded(child: _buildExpectimaxPane()),
                  ],
                )
              : showEngine
                  ? _buildEnginePane()
                  : _buildExpectimaxPane(),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          if (_settings.showEngineDock)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                'Stockfish PV',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.stockfishColor(),
                ),
              ),
            ),
          if (_settings.showEngineDock && _settings.showExpectimaxDock)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('·', style: TextStyle(color: Colors.grey[600])),
            ),
          if (_settings.showExpectimaxDock)
            Text(
              'Expectimax PV (on-the-fly)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.expectimaxColor(),
              ),
            ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 18),
            tooltip: 'Analysis settings',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => showAnalysisSettingsSheet(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBar() {
    final discovery = _analysis.discoveryResult.value;
    String engineLabel = '—';
    if (discovery.lines.isNotEmpty) {
      final top = discovery.lines.first;
      engineLabel = formatEvalDisplay(
        scoreCp: top.effectiveCp,
        scoreMate: top.scoreMate,
      );
    }

    String exLabel = '—';
    String? exRaw;
    final prog = _onTheFly.progressiveLines;
    if (prog.lines.isNotEmpty) {
      final line = prog.lines.first;
      exLabel = _formatExEval(line.expectedEvalCp);
      if (line.evalCp != null) {
        exRaw = _formatExEval(line.evalCp!);
      }
    }

    return Material(
      color: Colors.grey.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Tooltip(
              message:
                  'Best engine evaluation at this position (raw Stockfish).',
              child: _SummaryChip(
                label: 'Engine',
                value: engineLabel,
                color: AppColors.stockfishColor(),
              ),
            ),
            const SizedBox(width: 16),
            Tooltip(
              message: exRaw != null
                  ? 'Expectimax practical eval (V → cp).\n'
                      'Accounts for likely opponent replies.\n'
                      'Raw leaf engine: $exRaw'
                  : 'Expectimax practical eval (V → cp).\n'
                      'At our moves: max child V. At opponent moves: '
                      'Σ pᵢ·V(childᵢ) plus tail for uncovered probability.',
              child: _SummaryChip(
                label: 'Expectimax',
                value: exLabel,
                color: AppColors.expectimaxColor(),
              ),
            ),
            if (prog.isComputing) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.expectimaxColor(),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${prog.bestCompletedDepth}/${prog.targetMaxDepth}',
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatExEval(int cp) {
    if (isMateEval(cp)) return cp > 0 ? '# ' : '-# ';
    final sign = cp >= 0 ? '+' : '';
    return '$sign${(cp / 100).toStringAsFixed(2)}';
  }

  Widget _buildEnginePane() {
    return UnifiedEnginePane(
      fen: widget.controller.fen,
      isActive: _engineActive,
      compact: true,
      isUserTurn: widget.controller.position.turn ==
          (widget.controller.isRepertoireWhite ? Side.white : Side.black),
      currentMoveSequence: widget.controller.currentMoveSequence,
      isWhiteRepertoire: widget.controller.isRepertoireWhite,
      boardPreview: widget.boardPreview,
      onMoveSelected: (uciMove) {
        final san = uciToSan(widget.controller.fen, uciMove);
        if (san != uciMove) {
          widget.controller.playMove(san);
        }
      },
      onLineMoveTapped: (sanMoves, index) {
        widget.controller.applyLineFromCurrent(sanMoves, index);
        widget.boardPreview.clearPreview();
      },
      onSetRoot: widget.controller.rootMoves.isEmpty
          ? () async {
              await widget.controller.setRootPosition();
              EngineSettings().probabilityStartMoves =
                  widget.controller.rootMoves;
            }
          : null,
      onOpenSettings: () => showAnalysisSettingsSheet(context),
    );
  }

  bool _hasPrecomputedExpectimax(String fen) {
    if (widget.tree == null || widget.treeConfig == null) return false;
    return hasPrecomputedExpectimaxAtPly(
      widget.tree!,
      fen,
      _settings.onTheFlyMaxDepth,
    );
  }

  Widget _buildExpectimaxPane() {
    return ExpectimaxPanelHost(
      controller: widget.controller,
      tree: widget.tree,
      treeConfig: widget.treeConfig,
      fenMap: widget.fenMap,
      boardPreview: widget.boardPreview,
      coherenceResult: widget.coherenceResult,
      isGenerating: widget.isGenerating,
      isGenerationPaused: widget.isGenerationPaused,
      onTheFlyService: _onTheFly,
      compact: true,
      onOpenSettings: () => showAnalysisSettingsSheet(context),
      autoComputeEnabled: false,
      onMoveSelected: (san) => widget.controller.playMove(san),
      onLineMoveClicked: (sanMoves, index) {
        widget.controller.applyLineFromCurrent(sanMoves, index);
        widget.boardPreview.clearPreview();
      },
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryChip({
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            color: color,
          ),
        ),
      ],
    );
  }
}
