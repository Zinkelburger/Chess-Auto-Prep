/// Configuration surface for repertoire generation.
///
/// This widget only collects settings and hands a [GenerationRequest] to the
/// [GenerationSessionController], which owns the whole pipeline.  The host
/// hides this tab while a build runs (progress lives in the Jobs panel), so
/// nothing here depends on staying mounted during generation.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/generation_session_controller.dart';
import '../models/build_tree_node.dart';
import '../models/repertoire_metadata.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/tree_serialization.dart';
import '../services/storage/storage_factory.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/movetext_builder.dart';
import 'generation/generation_config_form.dart';
import 'starting_position_card.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final RepertoireMetadata? currentRepertoire;
  final List<String> currentMoveSequence;

  /// The repertoire's own starting position (standard FEN for a repertoire
  /// that starts from the initial position).
  final String repertoireStartFen;

  final void Function(List<GeneratedLineExport> lines) onLinesSaved;
  final GenerationSessionController generationController;

  /// Move sequences of the lines the repertoire already holds, so the
  /// export can skip the ones a previous build already wrote.
  final Iterable<List<String>> existingLineMoves;

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.repertoireStartFen,
    required this.onLinesSaved,
    required this.generationController,
    this.existingLineMoves = const [],
  });

  @override
  State<RepertoireGenerationTab> createState() =>
      RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  final GlobalKey<GenerationConfigFormState> _configFormKey =
      GlobalKey<GenerationConfigFormState>();
  final ScrollController _scrollCtrl = ScrollController();

  BuildTree? _savedPartialTree;

  @override
  void initState() {
    super.initState();
    unawaited(_checkForPartialTree());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RepertoireGenerationTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath = oldWidget.currentRepertoire?.filePath;
    final newPath = widget.currentRepertoire?.filePath;
    if (oldPath != newPath) {
      _savedPartialTree = null;
      unawaited(_checkForPartialTree());
    }
  }

  // ── DB Explorer seeding ──────────────────────────────────────────────

  /// Pre-configure DB Explorer mode with the given PGN file paths and
  /// minimum game count.  Called by [RepertoireScreen] when the user
  /// triggers "Generate repertoire from games" elsewhere in the app.
  ///
  /// Retries across frames while the config form mounts, and only
  /// auto-starts after the seed has actually been applied — a missed seed
  /// must never launch a build with a stale configuration.
  void seedDbExplorer({
    required List<String> pgnPaths,
    int minGames = 1,
    bool autoStart = false,
  }) {
    _seedWhenFormReady(
      pgnPaths: pgnPaths,
      minGames: minGames,
      autoStart: autoStart,
      triesLeft: 5,
    );
  }

  void _seedWhenFormReady({
    required List<String> pgnPaths,
    required int minGames,
    required bool autoStart,
    required int triesLeft,
  }) {
    if (!mounted) return;
    final form = _configFormKey.currentState;
    if (form == null) {
      if (triesLeft <= 0) return;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _seedWhenFormReady(
          pgnPaths: pgnPaths,
          minGames: minGames,
          autoStart: autoStart,
          triesLeft: triesLeft - 1,
        ),
      );
      return;
    }
    form.seedDbExplorer(pgnPaths: pgnPaths, minGames: minGames);
    if (autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.generationController.isGenerating) {
          unawaited(_startTreeBuild());
        }
      });
    }
  }

  // ── Partial tree handling ────────────────────────────────────────────

  String? _partialTreePath() {
    final filePath = widget.currentRepertoire?.filePath;
    if (filePath == null || filePath.isEmpty) return null;
    final base = p.withoutExtension(filePath);
    return '${base}_partial_tree.json';
  }

  Future<void> _checkForPartialTree() async {
    final path = _partialTreePath();
    if (path == null) return;
    final storage = StorageFactory.instance;
    if (await storage.fileExists(path)) {
      try {
        final json = await storage.readFile(path);
        if (json == null) return;
        final tree = await Isolate.run(() => deserializeTree(json));
        // The card reports the saved target depth; the Max line length field
        // is left alone. Rewriting it here used to change the depth of the
        // next *fresh* build without a word.
        //
        // A tree that finished exploring but was cancelled before its lines
        // were built is offered too — Finish Now is exactly what it needs.
        if (mounted) setState(() => _savedPartialTree = tree);
      } catch (e) {
        debugPrint('[RepertoireGenTab] Failed to load partial tree: $e');
      }
    } else if (_savedPartialTree != null && mounted) {
      setState(() => _savedPartialTree = null);
    }
  }

  Future<void> _deletePartialTree() async {
    final path = _partialTreePath();
    if (path == null) return;
    try {
      await StorageFactory.instance.deleteFile(path);
    } catch (e) {
      debugPrint('[RepertoireGenTab] Failed to delete tree file: $e');
    }
  }

  /// Confirms before throwing away an unfinished build.
  ///
  /// The file is the only copy of a search that may have run for hours, and
  /// deleting it is not undoable — so this asks first and says what is being
  /// lost, the way deleting a saved preset does.
  Future<void> _confirmDiscardPartialTree(BuildTree tree) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unfinished build?'),
        content: Text(
          '${tree.totalNodes} nodes explored to depth ${tree.maxPlyReached} '
          'will be deleted. This cannot be undone, and the search would have '
          'to start again from the beginning.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard != true) return;
    await _deletePartialTree();
    if (mounted) setState(() => _savedPartialTree = null);
  }

  /// Whether the saved partial tree can resume safely: either it recorded
  /// its line prefix, or the board is at the position it was built from.
  bool _canResumeSavedTree(BuildTree tree) =>
      tree.startMoves.isNotEmpty || tree.root.fen == widget.fen;

  // ── Build start ──────────────────────────────────────────────────────

  Future<void> _startTreeBuild({
    BuildTree? existingTree,
    int? maxPlyOverride,
  }) async {
    final ctrl = widget.generationController;
    if (ctrl.isGenerating) return;
    final form = _configFormKey.currentState;
    if (form == null) return;

    final validationError = form.validateBeforeStart();
    if (validationError != null) {
      showAppSnackBar(context, validationError, isError: true);
      return;
    }

    final filePath = widget.currentRepertoire?.filePath;
    if (filePath == null || filePath.isEmpty) {
      showAppSnackBar(context, 'Select a repertoire first.', isError: true);
      return;
    }

    final TreeBuildConfig config;
    if (existingTree != null) {
      // Resume keeps the saved config; only the depth target may change.
      final saved = TreeBuildConfig.fromJson(
        existingTree.configSnapshot,
        startFen: existingTree.root.fen,
      );
      final ui = form.toConfig(
        startFen: widget.fen,
        playAsWhite: widget.isWhiteRepertoire,
      );
      config = saved.copyWith(maxPly: maxPlyOverride ?? ui.maxPly);
      existingTree.configSnapshot = Map<String, dynamic>.from(config.toJson());
    } else {
      config = form.toConfig(
        startFen: widget.fen,
        playAsWhite: widget.isWhiteRepertoire,
      );
    }

    if (existingTree == null) {
      await _deletePartialTree();
    }
    form.resetChessDbApiUsageForBuild(config.chessDbApiDailyQuota);
    if (mounted) setState(() => _savedPartialTree = null);

    final request = GenerationRequest(
      config: config,
      repertoireFilePath: filePath,
      buildRootFen: widget.fen,
      lineMovePrefix: List.unmodifiable(widget.currentMoveSequence),
      repertoireStartFen: widget.repertoireStartFen,
      existingTree: existingTree,
      onLinesSaved: widget.onLinesSaved,
      existingLineKeys: {
        for (final moves in widget.existingLineMoves)
          GenerationRequest.lineKey(moves),
      },
    );
    unawaited(
      ctrl.startBuild(request).whenComplete(() {
        if (mounted) unawaited(_checkForPartialTree());
      }),
    );
  }

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.generationController,
      builder: (context, _) {
        final ctrl = widget.generationController;
        final statusText = ctrl.isGenerating
            ? ctrl.progress.status
            : ctrl.lastRunSummary;
        return Column(
          children: [
            Expanded(
              // Width-cap outside the scroll view so the scrollbar thumb sits
              // beside the form instead of at the far window edge.
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Scrollbar(
                    thumbVisibility: true,
                    controller: _scrollCtrl,
                    child: SingleChildScrollView(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStartingPositionBanner(context),
                          const SizedBox(height: 8),
                          GenerationConfigForm(
                            key: _configFormKey,
                            initialConfig: ctrl.lastConfig,
                            isGenerating: ctrl.isGenerating,
                            playAsWhite: widget.isWhiteRepertoire,
                          ),
                          if (_savedPartialTree != null &&
                              !ctrl.isGenerating) ...[
                            const SizedBox(height: 8),
                            _buildPartialTreeCard(_savedPartialTree!),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      statusText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ctrl.lastError != null
                            ? AppColors.danger
                            : AppColors.onSurfaceMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: ctrl.isGenerating ? null : _startTreeBuild,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Generate Repertoire'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStartingPositionBanner(BuildContext context) {
    return StartingPositionCard(
      label: 'GENERATING FROM',
      fen: widget.fen,
      moveSans: widget.currentMoveSequence,
      flipped: !widget.isWhiteRepertoire,
    );
  }

  /// The saved build's move prefix as movetext (`1.e4 c5 2.Nf3`), or null
  /// when it recorded none.
  static String? _savedTreeMovetext(BuildTree tree) {
    final moves = tree.startMoves
        .split(RegExp(r'\s+'))
        .where((m) => m.isNotEmpty)
        .toList();
    if (moves.isEmpty) return null;
    return buildNumberedMovetext(moves);
  }

  /// The Max line length the form currently shows, which is what Resume
  /// continues toward.
  int? _formMaxPly() {
    final text = _configFormKey.currentState?.maxPlyText;
    return text == null ? null : int.tryParse(text.trim());
  }

  Widget _buildPartialTreeCard(BuildTree tree) {
    // Rebuild as the field is edited so the resume wording stays true.
    final maxPlyListenable = _configFormKey.currentState?.maxPlyListenable;
    if (maxPlyListenable == null) return _partialTreeCardBody(tree);
    return ListenableBuilder(
      listenable: maxPlyListenable,
      builder: (_, _) => _partialTreeCardBody(tree),
    );
  }

  Widget _partialTreeCardBody(BuildTree tree) {
    final canResume = _canResumeSavedTree(tree);
    // Fully explored: there is nothing to resume, only lines to build.
    final exploredFully = tree.buildComplete;
    final targetDepth = tree.configSnapshot['max_depth'];
    final movetext = _savedTreeMovetext(tree);
    final formMaxPly = _formMaxPly();
    // Resumable from elsewhere on the board: the tree recorded its own
    // moves, so it continues from *its* root, not from the position shown
    // in the banner above.
    final resumesElsewhere = canResume && tree.root.fen != widget.fen;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warningTint,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.pause_circle,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Text(
                exploredFully
                    ? 'Explored build not yet exported'
                    : 'Unfinished build available',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${tree.totalNodes} nodes, depth ${tree.maxPlyReached}'
            '${targetDepth is num ? '\nWas heading for depth ${targetDepth.toInt()}' : ''}'
            '${movetext != null ? '\nFrom: $movetext' : ''}',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 4),
          Text(
            exploredFully
                ? 'The search finished but the run was cancelled before any '
                      'lines were built. Finish Now builds them from the '
                      'explored tree.'
                : formMaxPly != null
                ? 'Resume continues to the Max line length above '
                      '($formMaxPly half-moves); Finish Now builds lines from '
                      'what is already explored.'
                : 'Resume continues to the Max line length above; Finish Now '
                      'builds lines from what is already explored.',
            style: AppTextStyles.caption,
          ),
          if (resumesElsewhere) ...[
            const SizedBox(height: 4),
            const Text(
              'This build starts from the position listed above, not from '
              'the board — resuming it keeps the moves it recorded.',
              style: AppTextStyles.caption,
            ),
          ],
          if (!canResume) ...[
            const SizedBox(height: 4),
            const Text(
              'This build started from a different position and did not '
              'record its moves — it cannot be resumed. Discard it, or '
              'navigate to the position it was built from.',
              style: TextStyle(fontSize: 12, color: AppColors.warning),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!exploredFully)
                Tooltip(
                  message: formMaxPly != null
                      ? 'Continues the search to $formMaxPly half-moves (the '
                            'Max line length above), then builds lines.'
                      : 'Continues the search toward the Max line length set '
                            'above, then builds lines.',
                  child: OutlinedButton.icon(
                    onPressed: canResume
                        ? () => _startTreeBuild(existingTree: tree)
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Resume Exploring'),
                  ),
                ),
              Tooltip(
                message:
                    'Stops at depth ${tree.maxPlyReached} already reached '
                    'and builds lines from the tree as it is.',
                child: OutlinedButton.icon(
                  onPressed: canResume
                      ? () => _startTreeBuild(
                          existingTree: tree,
                          maxPlyOverride: tree.maxPlyReached,
                        )
                      : null,
                  icon: const Icon(Icons.outlined_flag),
                  label: const Text('Finish Now'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => unawaited(_confirmDiscardPartialTree(tree)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger),
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Discard'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
