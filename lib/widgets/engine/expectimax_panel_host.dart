/// Expectimax panel with precomputed tree or on-the-fly progressive build.
///
/// Shared by [RepertoireAnalysisDock] and [EditContextZone] so both paths use
/// the same default: on-the-fly when the current FEN has no precomputed node.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';

import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart';
import '../../models/engine_settings.dart';
import '../../services/coherence_service.dart';
import '../../services/engine/engine_lifecycle.dart';
import '../../services/expectimax_line_service.dart'
    show hasPrecomputedExpectimaxAtPly;
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../services/on_the_fly_expectimax_service.dart';
import 'expectimax_lines_pane.dart';

class ExpectimaxPanelHost extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool compact;
  final VoidCallback? onOpenSettings;
  final void Function(String san)? onMoveSelected;
  final void Function(List<String> sanMoves, int index)? onLineMoveClicked;

  /// When false, auto on-the-fly compute is paused (e.g. panel hidden).
  final bool autoComputeEnabled;

  /// Optional shared service (e.g. [RepertoireAnalysisDock] summary bar).
  final OnTheFlyExpectimaxService? onTheFlyService;

  const ExpectimaxPanelHost({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.compact = false,
    this.onOpenSettings,
    this.onMoveSelected,
    this.onLineMoveClicked,
    this.autoComputeEnabled = true,
    this.onTheFlyService,
  });

  @override
  State<ExpectimaxPanelHost> createState() => _ExpectimaxPanelHostState();
}

class _ExpectimaxPanelHostState extends State<ExpectimaxPanelHost> {
  OnTheFlyExpectimaxService? _ownedOnTheFly;
  final EngineSettings _settings = EngineSettings();
  bool _autoComputeScheduled = false;

  OnTheFlyExpectimaxService get _onTheFly =>
      widget.onTheFlyService ?? _ownedOnTheFly!;

  bool get _ownsOnTheFly => widget.onTheFlyService == null;

  @override
  void initState() {
    super.initState();
    if (_ownsOnTheFly) {
      _ownedOnTheFly = OnTheFlyExpectimaxService();
    }
    widget.controller.addListener(_scheduleAutoCompute);
    _settings.addListener(_scheduleAutoCompute);
    _onTheFly.addListener(_onFlyUpdated);
    _scheduleAutoCompute();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleAutoCompute);
    _settings.removeListener(_scheduleAutoCompute);
    _onTheFly.removeListener(_onFlyUpdated);
    if (_ownsOnTheFly) {
      _ownedOnTheFly?.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ExpectimaxPanelHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree != widget.tree ||
        oldWidget.treeConfig != widget.treeConfig ||
        oldWidget.isGenerating != widget.isGenerating ||
        oldWidget.isGenerationPaused != widget.isGenerationPaused ||
        oldWidget.autoComputeEnabled != widget.autoComputeEnabled) {
      _scheduleAutoCompute();
    }
  }

  void _onFlyUpdated() {
    if (mounted) setState(() {});
  }

  void _scheduleAutoCompute() {
    if (_autoComputeScheduled) return;
    _autoComputeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoComputeScheduled = false;
      if (mounted) _maybeAutoCompute();
    });
  }

  void _maybeAutoCompute() {
    if (!_ownsOnTheFly && widget.onTheFlyService != null) return;
    if (!widget.autoComputeEnabled) return;
    if (EngineLifecycle().state == EngineState.off ||
        EngineLifecycle().state == EngineState.generating) {
      return;
    }
    if (widget.isGenerating && !widget.isGenerationPaused) return;

    final fen = widget.controller.fen;
    if (_onTheFly.currentFen == fen &&
        (_onTheFly.state == OnTheFlyState.computing ||
            (_onTheFly.state == OnTheFlyState.ready &&
                _onTheFly.progressiveLines.lines.isNotEmpty))) {
      return;
    }

    if (_hasPrecomputedExpectimax(fen)) return;

    _onTheFly.ensureRunning(
      fen: fen,
      playAsWhite: widget.controller.isRepertoireWhite,
      mainTree: widget.tree,
      mainConfig: widget.treeConfig,
      mainFenMap: widget.fenMap,
      maxDepth: _settings.onTheFlyMaxDepth,
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

  @override
  Widget build(BuildContext context) {
    final fen = widget.controller.fen;
    final useMain = _hasPrecomputedExpectimax(fen);

    return ExpectimaxLinesPane(
      fen: fen,
      tree: useMain ? widget.tree : _onTheFly.currentTree,
      config: useMain ? widget.treeConfig : _onTheFly.currentConfig,
      fenMap: useMain ? widget.fenMap : _onTheFly.currentFenMap,
      isWhiteRepertoire: widget.controller.isRepertoireWhite,
      boardPreview: widget.boardPreview,
      coherenceResult: widget.coherenceResult,
      progressiveSnapshot: useMain ? null : _onTheFly.progressiveLines,
      onTheFlyMode: !useMain,
      compact: widget.compact,
      onOpenSettings: widget.onOpenSettings,
      onMoveSelected: widget.onMoveSelected ??
          widget.controller.playMove,
      onLineMoveClicked: widget.onLineMoveClicked ??
          (sanMoves, index) {
            widget.controller.applyLineFromCurrent(sanMoves, index);
            widget.boardPreview.clearPreview();
          },
    );
  }
}
