/// Side-by-side Stockfish + expectimax under the PGN editor.
///
/// The engine half is live; the expectimax half is read from the built tree
/// and never runs anything.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../core/generation_session_controller.dart';
import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/engine_settings.dart';
import '../services/analysis_service.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../services/coherence_service.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/expectimax_line_service.dart' show findNodeByFen;
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/chess_utils.dart'
    show formatEvalDisplay, formatPackedEval, uciToSan;
import '../utils/ease_utils.dart' show expectedCpFromWinProb;
import 'analysis/analysis_panels_dialog.dart';
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

  /// Enables on-demand probes from the expectimax pane.
  final GenerationSessionController? generation;

  const RepertoireAnalysisDock({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    required this.isActive,
    this.generation,
  });

  @override
  State<RepertoireAnalysisDock> createState() => _RepertoireAnalysisDockState();
}

class _RepertoireAnalysisDockState extends State<RepertoireAnalysisDock> {
  final EngineSettings _settings = EngineSettings.instance;
  final AnalysisService _analysis = AnalysisService.instance;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleSetState);
    _settings.addListener(_scheduleSetState);
    EngineLifecycle.instance.addListener(_scheduleSetState);
    _analysis.discoveryResult.addListener(_scheduleSetState);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleSetState);
    _settings.removeListener(_scheduleSetState);
    EngineLifecycle.instance.removeListener(_scheduleSetState);
    _analysis.discoveryResult.removeListener(_scheduleSetState);
    super.dispose();
  }

  void _scheduleSetState() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  bool get _engineActive =>
      widget.isActive &&
      EngineLifecycle.instance.state != EngineState.off &&
      EngineLifecycle.instance.state != EngineState.generating;

  @override
  Widget build(BuildContext context) {
    final showEngine = _settings.showEngineDock;
    final showEx = _settings.showExpectimaxDock;

    if (!showEngine && !showEx) {
      return Center(
        child: TextButton.icon(
          onPressed: () => showAnalysisPanelsDialog(context),
          icon: const Icon(Icons.view_column),
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
                    const VerticalDivider(
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
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.stockfishColor(),
                ),
              ),
            ),
          if (_settings.showEngineDock && _settings.showExpectimaxDock)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '·',
                style: TextStyle(color: AppColors.onSurfaceMuted),
              ),
            ),
          if (_settings.showExpectimaxDock)
            Text(
              'Expectimax · from built tree',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.expectimaxColor(),
              ),
            ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.view_column_outlined, size: 18),
            tooltip: 'Analysis panels',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => showAnalysisPanelsDialog(context),
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

    // The position's own stored value — what the repertoire expects to get
    // out of this position in practice, next to what the engine sees now.
    String exLabel = '—';
    String? exRaw;
    final node = _treeNodeAtCursor();
    if (node != null && node.hasExpectimax) {
      exLabel = _formatExEval(expectedCpFromWinProb(node.expectimaxValue));
      if (node.hasEngineEval && widget.treeConfig != null) {
        exRaw = _formatExEval(node.evalForUs(widget.treeConfig!.playAsWhite));
      }
    }

    return Material(
      color: AppColors.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Tooltip(
              message:
                  'Best engine evaluation at this position (raw Stockfish).',
              child: _SummaryChip(label: 'Engine', value: engineLabel),
            ),
            const SizedBox(width: 16),
            Tooltip(
              message: node == null
                  ? 'Practical value of this position from the built tree.\n'
                        'The build never reached this position.'
                  : exRaw != null
                  ? 'Practical value of this position from the built tree:\n'
                        'the engine eval folded with how often opponents go\n'
                        'wrong from here.  Build-time engine eval: $exRaw'
                  : 'Practical value of this position from the built tree:\n'
                        'the engine eval folded with how often opponents go\n'
                        'wrong from here.',
              child: _SummaryChip(label: 'Expectimax', value: exLabel),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatExEval(int cp) => formatPackedEval(cp, decimals: 2);

  Widget _buildEnginePane() {
    return UnifiedEnginePane(
      fen: widget.controller.fen,
      isActive: _engineActive,
      compact: true,
      isUserTurn:
          widget.controller.position.turn ==
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
              EngineSettings.instance.probabilityStartMoves =
                  widget.controller.rootMoves;
            }
          : null,
    );
  }

  /// The built tree's node for the cursor position, resolving a
  /// transposition leaf to the node that carries its subtree.
  BuildTreeNode? _treeNodeAtCursor() {
    final tree = widget.tree;
    if (tree == null) return null;
    final fen = widget.controller.fen;
    final canonical = widget.fenMap?.getCanonical(fen);
    if (canonical != null && canonical.children.isNotEmpty) return canonical;
    return findNodeByFen(tree, fen) ?? canonical;
  }

  Widget _buildExpectimaxPane() {
    return ExpectimaxPanelHost(
      controller: widget.controller,
      tree: widget.tree,
      treeConfig: widget.treeConfig,
      fenMap: widget.fenMap,
      boardPreview: widget.boardPreview,
      coherenceResult: widget.coherenceResult,
      compact: true,
      generation: widget.generation,
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

  const _SummaryChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: AppTextStyles.caption.copyWith(fontSize: 12)),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            fontFamily: AppTextStyles.monoFamily,
          ),
        ),
      ],
    );
  }
}
