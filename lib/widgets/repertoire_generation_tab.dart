/// Configuration surface for repertoire generation.
///
/// This widget only collects settings and hands a [GenerationRequest] to the
/// [GenerationSessionController], which owns the whole pipeline.  The host
/// hides this tab while a build runs (progress lives in the Jobs panel), so
/// nothing here depends on staying mounted during generation.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/generation_session_controller.dart';
import '../models/build_tree_node.dart';
import '../models/repertoire_metadata.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/pgn_export.dart';
import '../services/generation/tree_serialization.dart';
import '../services/storage/storage_factory.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import 'generation/generation_config_form.dart';

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

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.repertoireStartFen,
    required this.onLinesSaved,
    required this.generationController,
  });

  @override
  State<RepertoireGenerationTab> createState() =>
      RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  final GlobalKey<GenerationConfigFormState> _configFormKey =
      GlobalKey<GenerationConfigFormState>();

  BuildTree? _savedPartialTree;

  @override
  void initState() {
    super.initState();
    _checkForPartialTree();
  }

  @override
  void didUpdateWidget(covariant RepertoireGenerationTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath = oldWidget.currentRepertoire?.filePath;
    final newPath = widget.currentRepertoire?.filePath;
    if (oldPath != newPath) {
      _savedPartialTree = null;
      _checkForPartialTree();
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
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedWhenFormReady(
            pgnPaths: pgnPaths,
            minGames: minGames,
            autoStart: autoStart,
            triesLeft: triesLeft - 1,
          ));
      return;
    }
    form.seedDbExplorer(pgnPaths: pgnPaths, minGames: minGames);
    if (autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.generationController.isGenerating) {
          _startTreeBuild();
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
        final tree = deserializeTree(json);
        if (!tree.buildComplete && mounted) {
          setState(() {
            final md = tree.configSnapshot['max_depth'];
            if (md is num) {
              _configFormKey.currentState?.setMaxPly(md.toInt());
            }
            _savedPartialTree = tree;
          });
        }
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

  /// Whether the saved partial tree can resume safely: either it recorded
  /// its line prefix, or the board is at the position it was built from.
  bool _canResumeSavedTree(BuildTree tree) =>
      tree.startMoves.isNotEmpty || tree.root.fen == widget.fen;

  // ── Build start ──────────────────────────────────────────────────────

  Future<void> _startTreeBuild({BuildTree? existingTree}) async {
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
      config = saved.copyWith(maxPly: ui.maxPly);
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
    );
    unawaited(ctrl.startBuild(request).whenComplete(() {
      if (mounted) _checkForPartialTree();
    }));
  }

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.generationController,
      builder: (context, _) {
        final ctrl = widget.generationController;
        final statusText =
            ctrl.isGenerating ? ctrl.progressStatus : ctrl.lastRunSummary;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Generate Repertoire',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _buildStartingPositionBanner(context),
              const SizedBox(height: 8),
              GenerationConfigForm(
                key: _configFormKey,
                initialConfig: ctrl.lastConfig,
                isGenerating: ctrl.isGenerating,
                playAsWhite: widget.isWhiteRepertoire,
              ),
              const SizedBox(height: 8),
              if (_savedPartialTree != null && !ctrl.isGenerating) ...[
                _buildPartialTreeCard(_savedPartialTree!),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                onPressed: ctrl.isGenerating ? null : _startTreeBuild,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Build Repertoire Tree'),
              ),
              if (statusText.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  statusText,
                  style: TextStyle(
                    color:
                        ctrl.lastError != null ? AppColors.danger : Colors.grey,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _configFormKey.currentState?.selectionModeDescription() ?? '',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStartingPositionBanner(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final fromInitial = widget.currentMoveSequence.isEmpty;
    final positionText = fromInitial
        ? 'Initial Position'
        : movesToPgnMoveText(widget.currentMoveSequence);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: primary, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.my_location, size: 28, color: primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GENERATING FROM',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  positionText,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartialTreeCard(BuildTree tree) {
    final canResume = _canResumeSavedTree(tree);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warningSurface.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.pause_circle, size: 18, color: AppColors.warning),
              SizedBox(width: 8),
              Text(
                'Unfinished Build Available',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${tree.totalNodes} nodes, depth ${tree.maxPlyReached}'
            '${tree.startMoves.isNotEmpty ? '\nFrom: ${tree.startMoves}' : ''}',
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
          ),
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
              FilledButton.icon(
                onPressed: canResume
                    ? () {
                        _configFormKey.currentState?.setMaxPly(
                          tree.maxPlyReached,
                        );
                        _startTreeBuild(existingTree: tree);
                      }
                    : null,
                icon: const Icon(Icons.check),
                label: const Text('Build Lines Now'),
              ),
              OutlinedButton.icon(
                onPressed: canResume
                    ? () => _startTreeBuild(existingTree: tree)
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume Build'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _deletePartialTree();
                  setState(() => _savedPartialTree = null);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
