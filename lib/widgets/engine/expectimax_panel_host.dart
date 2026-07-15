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

  /// Analyze this FEN instead of the controller cursor (e.g. the
  /// build-by-playing scratchpad position).
  final String? fenOverride;

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
    this.fenOverride,
  });

  String get effectiveFen => fenOverride ?? controller.fen;

  @override
  State<ExpectimaxPanelHost> createState() => _ExpectimaxPanelHostState();
}

class _ExpectimaxPanelHostState extends State<ExpectimaxPanelHost> {
  OnTheFlyExpectimaxService? _ownedOnTheFly;
  final EngineSettings _settings = EngineSettings.instance;
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
    // Engine toggled on / generation finished should kick off compute (and
    // rebuild so the idle "engine is off" message clears).
    EngineLifecycle.instance.addListener(_onLifecycleChanged);
    _onTheFly.addListener(_onFlyUpdated);
    _scheduleAutoCompute();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleAutoCompute);
    _settings.removeListener(_scheduleAutoCompute);
    EngineLifecycle.instance.removeListener(_onLifecycleChanged);
    _onTheFly.removeListener(_onFlyUpdated);
    if (_ownsOnTheFly) {
      _ownedOnTheFly?.dispose();
    }
    super.dispose();
  }

  void _onLifecycleChanged() {
    if (!mounted) return;
    _scheduleAutoCompute();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ExpectimaxPanelHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tree != widget.tree ||
        oldWidget.treeConfig != widget.treeConfig ||
        oldWidget.isGenerating != widget.isGenerating ||
        oldWidget.isGenerationPaused != widget.isGenerationPaused ||
        oldWidget.autoComputeEnabled != widget.autoComputeEnabled ||
        oldWidget.fenOverride != widget.fenOverride) {
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
    if (EngineLifecycle.instance.state == EngineState.generating) return;
    if (widget.isGenerating && !widget.isGenerationPaused) return;
    if (EngineLifecycle.instance.state == EngineState.off) {
      // Expectimax being enabled IS the request to run the shared pool —
      // turn it on instead of idling behind a message.  The lifecycle
      // listener re-enters here once the engine reaches idle.
      EngineLifecycle.instance.toggleOn();
      return;
    }

    final fen = widget.effectiveFen;
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

  /// Why auto-compute is currently blocked, or null when it can run.
  /// Mirrors the early-return conditions in [_maybeAutoCompute].
  String? _notRunningReason() {
    if (EngineLifecycle.instance.state == EngineState.generating ||
        (widget.isGenerating && !widget.isGenerationPaused)) {
      return 'Paused while a repertoire is generating';
    }
    if (EngineLifecycle.instance.state == EngineState.off) {
      // Transient: auto-compute turns the engine on and re-runs.
      return 'Starting engine…';
    }
    if (!widget.autoComputeEnabled) {
      return 'Expectimax panel is hidden';
    }
    return null;
  }

  /// Retry is pointless mid-generation (the pool belongs to the build);
  /// everything else — engine off, error, timeout — is recoverable.
  bool get _retryAvailable =>
      EngineLifecycle.instance.state != EngineState.generating &&
      !(widget.isGenerating && !widget.isGenerationPaused);

  /// Force a fresh run — recovers from errors, timeouts, or a stuck state.
  /// Turns the global engine on if needed: an explicit compute request
  /// overrides the persisted engine kill switch.
  Future<void> _retry() async {
    if (EngineLifecycle.instance.state == EngineState.off) {
      await EngineLifecycle.instance.toggleOn();
      if (!mounted) return;
    }
    _onTheFly.cancel();
    _onTheFly.ensureRunning(
      fen: widget.effectiveFen,
      playAsWhite: widget.controller.isRepertoireWhite,
      mainTree: widget.tree,
      mainConfig: widget.treeConfig,
      mainFenMap: widget.fenMap,
      maxDepth: _settings.onTheFlyMaxDepth,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fen = widget.effectiveFen;
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
      notRunningReason: useMain ? null : _notRunningReason(),
      onRetry: useMain || !_retryAvailable ? null : _retry,
      compact: widget.compact,
      onOpenSettings: widget.onOpenSettings,
      onMoveSelected: widget.onMoveSelected ?? widget.controller.playMove,
      onLineMoveClicked:
          widget.onLineMoveClicked ??
          (sanMoves, index) {
            widget.controller.applyLineFromCurrent(sanMoves, index);
            widget.boardPreview.clearPreview();
          },
    );
  }
}
