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
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/repertoire_slice.dart';
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

  /// Removes the repertoire lines whose move-sequence keys are given, and
  /// reports how many went. Null when the host cannot edit the file, which
  /// hides the size control rather than offering a button that cannot work.
  final Future<int> Function(Set<String> droppedKeys)? onTrimLines;

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
    this.onTrimLines,
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

  /// Ranking of the finished build's lines, rebuilt whenever the tree
  /// changes. Null until there is a completed tree to slice.
  RepertoireSlicer? _slicer;
  BuildTree? _slicerTree;

  /// The size the control currently shows.
  int _keepLines = 0;
  bool _trimming = false;

  /// Memoised "how many lines in the file this cut would remove".
  ///
  /// Planning a cut walks the ranking and runs the transposition-owner fixed
  /// point. That is not something to redo on every frame of a slider drag —
  /// which is exactly what happened while this was memoised on [_keepLines],
  /// the one value the drag changes on every frame. It is now computed when the
  /// slider *settles*, and [_countedForKeep] says which cut the answer
  /// describes; while they disagree the count is shown as pending.
  int? _countedForKeep;
  int _willRemove = 0;

  /// True while the post-frame ranking of a newly finished tree is pending.
  bool _ranking = false;

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
          'will be moved to Chess Auto Prep recovery trash. The app will no '
          'longer resume that search.',
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
                          if (!ctrl.isGenerating) ...[..._buildSliceCard(ctrl)],
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
      sideLabel: widget.isWhiteRepertoire
          ? 'Preparing White'
          : 'Preparing Black',
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

  // ── Repertoire size ────────────────────────────────────────────────────

  /// Note that the finished tree changed, and rank its lines after this
  /// frame.
  ///
  /// Extraction and ranking are pure and synchronous, but they are not cheap:
  /// [RepertoireSlicer.forTree] extracts every line and runs a greedy
  /// weighted set cover over them. Running that from inside `build` stalls
  /// the frame that is trying to show the finished build. It is deferred to a
  /// post-frame callback instead, so the card can render "ranking…" and the
  /// stall — which is unavoidable on this isolate — at least happens with
  /// something on screen.
  void _refreshSlicer(GenerationSessionController ctrl) {
    final tree = ctrl.generatedTree;
    final config = ctrl.generatedTreeConfig;
    if (tree == null || config == null || ctrl.isExpectimaxProbe) {
      _slicer = null;
      _slicerTree = null;
      _countedForKeep = null;
      _ranking = false;
      return;
    }
    if (identical(tree, _slicerTree)) return;
    _slicerTree = tree;
    _slicer = null;
    _countedForKeep = null;
    _ranking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_slicerTree, tree)) return;
      _rankTree(tree, config, ctrl.generatedTreeFenMap);
    });
  }

  void _rankTree(BuildTree tree, TreeBuildConfig config, FenMap? fenMap) {
    RepertoireSlicer? slicer;
    var keep = _keepLines;
    try {
      final ranked = RepertoireSlicer.forTree(
        tree,
        config: config,
        fenMap: fenMap,
      );
      slicer = ranked.maxLines > 1 ? ranked : null;
      // Open on what the repertoire currently holds, so the control starts
      // by describing the file rather than proposing a change to it.
      final held = widget.existingLineMoves.length;
      keep = held > 0 && held <= ranked.maxLines ? held : ranked.maxLines;
    } catch (e) {
      debugPrint('[RepertoireGenTab] Could not rank lines: $e');
      slicer = null;
    }
    if (!mounted) return;
    setState(() {
      _slicer = slicer;
      _keepLines = keep;
      _ranking = false;
      _countedForKeep = null;
    });
    if (slicer != null) _countRemovals(slicer, keep);
  }

  /// Work out how many lines a cut of [keep] would remove, and show it.
  ///
  /// Called when the slider settles and once when the ranking lands — never
  /// from `build`.
  void _countRemovals(RepertoireSlicer slicer, int keep) {
    if (_countedForKeep == keep) return;
    final removals = slicer.plan(keep).removalsFrom(widget.existingLineMoves);
    if (!mounted) return;
    setState(() {
      _willRemove = removals;
      _countedForKeep = keep;
    });
  }

  /// "How much of this do I want to learn", asked once the build has produced
  /// something to look at.
  ///
  /// The build exports every line that teaches a decision no other kept line
  /// teaches. That is the honest maximum and it is usually more than anyone
  /// wants to study, so the size is chosen here — against a real line count
  /// and the coverage it buys — instead of as a percentage guessed before
  /// the build had run.
  List<Widget> _buildSliceCard(GenerationSessionController ctrl) {
    _refreshSlicer(ctrl);
    if (widget.onTrimLines == null) return const [];
    if (_ranking) {
      return const [
        SizedBox(height: 8),
        Text('Ranking the lines this build produced…'),
      ];
    }
    final slicer = _slicer;
    if (slicer == null) return const [];

    final max = slicer.maxLines;
    final keep = _keepLines.clamp(1, max);
    final coverage = (slicer.coverageAt(keep) * 100).round();
    // What the file answers once the folded sidelines are counted. Shown
    // only when it differs: otherwise it is the same number twice.
    final answered = (slicer.answeredCoverageAt(keep) * 100).round();
    final folded = slicer.foldedCount;
    // Deliberately not planning the cut here: see [_countRemovals]. While the
    // slider is mid-drag the count describes an older cut, so it is withheld
    // rather than shown wrong.
    final willRemove = _countedForKeep == keep ? _willRemove : null;

    return [
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceInset,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HOW MUCH TO KEEP',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$keep of $max lines · covers $coverage% of what you will face',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Slider(
              value: keep.toDouble(),
              min: 1,
              max: max.toDouble(),
              divisions: max > 1 ? max - 1 : null,
              label: '$keep',
              onChanged: _trimming
                  ? null
                  : (v) => setState(() => _keepLines = v.round()),
              // The count is planned here, not in `build`: a drag emits
              // `onChanged` every frame and `onChangeEnd` once.
              onChangeEnd: _trimming
                  ? null
                  : (v) => _countRemovals(slicer, v.round().clamp(1, max)),
            ),
            if (folded > 0 && answered > coverage)
              Text(
                '$folded near-duplicate lines are folded in as sidelines, '
                'so the file answers $answered%.',
                style: AppTextStyles.caption,
              ),
            const Text(
              'Lines are ordered by how much new ground each one breaks, so '
              'the ones dropped first are the ones that only answer a rarer '
              'try than a line you are keeping already. A line that differs '
              'from one you are keeping by a single move is written into it '
              'as a sideline instead of getting an entry of its own.',
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed:
                      (_trimming || willRemove == null || willRemove == 0)
                      ? null
                      : () => unawaited(_applySlice(slicer, keep)),
                  icon: const Icon(Icons.content_cut, size: 16),
                  label: Text(
                    willRemove == null
                        ? 'Counting…'
                        : willRemove == 0
                        ? 'Nothing to remove'
                        : 'Remove $willRemove line'
                              '${willRemove == 1 ? '' : 's'}',
                  ),
                ),
                const SizedBox(width: 8),
                if (willRemove != null && willRemove > 0)
                  const Expanded(
                    child: Text(
                      'Deletes them from the repertoire file. Re-run the '
                      'build to get them back.',
                      style: AppTextStyles.caption,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  Future<void> _applySlice(RepertoireSlicer slicer, int keep) async {
    final trim = widget.onTrimLines;
    if (trim == null) return;
    setState(() => _trimming = true);
    try {
      final plan = slicer.plan(keep);
      final removed = await trim(plan.droppedKeys);
      if (!mounted) return;
      showAppSnackBar(
        context,
        removed == 0
            ? 'Nothing to remove — the repertoire is already this size.'
            : 'Removed $removed line${removed == 1 ? '' : 's'}. '
                  '${plan.keep} left, covering '
                  '${(plan.coverage * 100).round()}% of what you will face.',
      );
    } finally {
      // The file just changed, so the memoised "would remove" count for this
      // cut is stale even though the cut itself did not move.
      _countedForKeep = null;
      if (mounted) {
        setState(() => _trimming = false);
        _countRemovals(slicer, keep);
      }
    }
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
