library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/build_tree_node.dart';
import '../models/repertoire_metadata.dart';
import '../services/storage/storage_factory.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/repertoire_selector.dart';
import '../services/generation/trap_extractor.dart';
import '../services/generation/tree_ease.dart';
import '../services/generation/tree_my_ease.dart';
import '../services/generation/tree_serialization.dart';
import '../services/generation/tree_build_progress.dart';
import '../services/generation/pgn_export.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/tree_build_service.dart';
import '../core/generation_session_controller.dart';
import '../theme/app_colors.dart';
import 'generation/build_progress_display.dart';
import 'generation/generation_config_form.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final RepertoireMetadata? currentRepertoire;
  final List<String> currentMoveSequence;
  final void Function(List<String> moves, String title, String pgn) onLineSaved;
  final GenerationSessionController generationController;

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.onLineSaved,
    required this.generationController,
  });

  @override
  State<RepertoireGenerationTab> createState() =>
      RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  TreeBuildService get _buildService =>
      widget.generationController.buildService;
  final GlobalKey<GenerationConfigFormState> _configFormKey =
      GlobalKey<GenerationConfigFormState>();

  static const int _pgnFlushEveryLines = 10;

  bool _isGenerating = false;
  bool _cancelRequested = false;
  bool _isPaused = false;

  /// Unified cancel signal: internal cancel OR external controller cancel.
  bool get _shouldStop =>
      _cancelRequested || !widget.generationController.isGenerating;
  int _buildGeneration = 0;
  String _status = 'Idle';
  int _nodes = 0;
  int _lines = 0;
  int _elapsedMs = 0;
  int _maxPlyConfig = 20;
  double? _nodesPerMinute;
  int _currentDepth = 0;
  int _unexploredAtDepth = 0;
  int _totalAtDepth = 0;
  int? _etaDepthSec;
  DateTime _lastProgressUpdate = DateTime(0);
  Timer? _uiPulseTimer;
  final PgnBatchWriter _pgnWriter = PgnBatchWriter();
  BuildTree? _savedPartialTree;

  @override
  void initState() {
    super.initState();
    _checkForPartialTree();
  }

  /// Pre-configure DB Explorer mode with the given PGN file paths and
  /// minimum game count. Called by [RepertoireScreen] when the user triggers
  /// "Generate repertoire from games" in the PGN Viewer.
  ///
  /// When [autoStart] is true the build kicks off automatically after the
  /// next frame (gives the widget tree time to rebuild with the new config).
  void seedDbExplorer({
    required List<String> pgnPaths,
    int minGames = 1,
    bool autoStart = false,
  }) {
    _configFormKey.currentState?.seedDbExplorer(
      pgnPaths: pgnPaths,
      minGames: minGames,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (autoStart && mounted && !_isGenerating) _startTreeBuild();
    });
  }

  @override
  void dispose() {
    _stopUiPulse();
    super.dispose();
  }

  static const Duration _uiPulseInterval = Duration(milliseconds: 250);

  void _startUiPulse() {
    _stopUiPulse();
    _uiPulseTimer = Timer.periodic(_uiPulseInterval, (_) => _onUiPulse());
  }

  void _stopUiPulse() {
    _uiPulseTimer?.cancel();
    _uiPulseTimer = null;
  }

  /// Keeps the UI isolate scheduling frames while generation runs so elapsed
  /// time (and other labels) advance smoothly between sparse [onProgress] calls.
  void _onUiPulse() {
    if (!mounted) {
      _stopUiPulse();
      return;
    }
    if (!_isGenerating) {
      _stopUiPulse();
      return;
    }
    setState(() {
      if (_buildService.isBuilding) {
        _elapsedMs = _buildService.buildElapsedMs;
        final api = _buildService.chessDbApiProvider;
        if (api != null) {
          _configFormKey.currentState?.updateChessDbApiUsage(
            api.usedToday,
            api.quotaLimit,
          );
        }
      }
    });
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

  Future<void> _savePartialTree() async {
    final tree = _buildService.currentTree;
    if (tree == null) return;
    final path = _partialTreePath();
    if (path == null) return;
    try {
      _applyKnownRootMoves(tree);
      final treeJson = serializeTree(tree);
      await StorageFactory.instance.writeFile(path, treeJson);
    } catch (e) {
      debugPrint('[RepertoireGenTab] Failed to save tree: $e');
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

  void cancelGeneration({String? reason}) {
    if (!_isGenerating) return;
    _cancelRequested = true;
    _buildService.stopBuild();
    _savePartialTree();
    if (mounted) {
      setState(() {
        _isPaused = false;
        _isGenerating = false;
        _status = reason ?? 'Cancelled ($_nodes nodes)';
        _nodesPerMinute = null;
        _etaDepthSec = null;
      });
    }
    _stopUiPulse();
    widget.generationController.markGenerating(false);
    _checkForPartialTree();
  }

  void togglePause() {
    if (!_isGenerating) return;
    final ctrl = widget.generationController;
    if (_isPaused) {
      ctrl.resumeBuild();
      setState(() {
        _isPaused = false;
        _status = 'Building: resumed...';
      });
    } else {
      ctrl.pauseBuild();
      setState(() {
        _isPaused = true;
        _status = 'Paused ($_nodes nodes)';
      });
    }
  }

  void _handleBuildProgress(BuildProgress p) {
    if (!mounted) return;
    _nodes = p.totalNodes;
    _maxPlyConfig = p.maxPlyConfig;
    _elapsedMs = p.elapsedMs;
    _nodesPerMinute = p.nodesPerMinute;
    _currentDepth = p.currentDepth;
    _unexploredAtDepth = p.unexploredAtDepth;
    _totalAtDepth = p.totalAtDepth;
    _etaDepthSec = p.etaDepthSeconds;

    final ctrl = widget.generationController;
    ctrl.progressNodes = _nodes;
    ctrl.progressDepth = _currentDepth;
    ctrl.progressNodesPerMinute = _nodesPerMinute;
    ctrl.progressEtaSec = _etaDepthSec?.toDouble();
    ctrl.progressElapsedMs = _elapsedMs;
    ctrl.progressStatus = _status;
    ctrl.notifyProgressChanged();

    final now = DateTime.now();
    if (now.difference(_lastProgressUpdate).inMilliseconds < 150) {
      return;
    }
    _lastProgressUpdate = now;
    setState(() {});
  }

  Future<void> _startTreeBuild({BuildTree? existingTree}) async {
    if (_isGenerating) return;
    final form = _configFormKey.currentState;
    if (form == null) return;

    final validationError = form.validateBeforeStart();
    if (validationError != null) {
      setState(() => _status = validationError);
      return;
    }

    final gen = ++_buildGeneration;
    final filePath = widget.currentRepertoire?.filePath;
    if (filePath == null || filePath.isEmpty) {
      setState(() => _status = 'Select a repertoire first.');
      return;
    }

    final TreeBuildConfig config;
    if (existingTree != null) {
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
      _deletePartialTree();
    }

    setState(() {
      _isGenerating = true;
      _cancelRequested = false;
      _isPaused = false;
      _savedPartialTree = null;
      _status = existingTree != null
          ? 'Phase 1: Resuming build...'
          : 'Phase 1: Building tree...';
      _nodes = existingTree?.totalNodes ?? 0;
      _lines = 0;
      _elapsedMs = 0;
      _nodesPerMinute = null;
      _currentDepth = existingTree?.maxPlyReached ?? 0;
      _unexploredAtDepth = 0;
      _totalAtDepth = 0;
      _etaDepthSec = null;
      form.resetChessDbApiUsageForBuild(config.chessDbApiDailyQuota);

      // Seed depth-layer counters so resume doesn't show "0 / 0 explored"
      // while BFS replays existing nodes toward the frontier.
      if (existingTree != null) {
        final frontierPly = TreeBuildService.minFrontierPly(existingTree.root);
        if (frontierPly != null) {
          final layer = TreeBuildProgressTracker.depthLayerStats(
            existingTree.root,
            frontierPly,
          );
          _currentDepth = frontierPly;
          _totalAtDepth = layer.$1;
          _unexploredAtDepth = layer.$2;
        } else if (existingTree.maxPlyReached > 0) {
          final layer = TreeBuildProgressTracker.depthLayerStats(
            existingTree.root,
            existingTree.maxPlyReached,
          );
          _totalAtDepth = layer.$1;
          _unexploredAtDepth = layer.$2;
        }
      }
    });
    _pgnWriter.clear();
    widget.generationController.setPartialSaveContext(
      repertoireFilePath: filePath,
      moveSequence: widget.currentMoveSequence,
      fen: widget.fen,
    );
    widget.generationController.onTreeReset();
    widget.generationController.markGenerating(true);
    _startUiPulse();

    var engineGenerationEntered = false;
    try {
      if (config.needsStockfish) {
        await EngineLifecycle().enterGeneration(config.resolvedEngineThreads);
        engineGenerationEntered = true;
      }

      final BuildTree tree;

      if (config.buildMode == BuildMode.dbExplorer) {
        tree = await _buildService.buildFromPgnFreqMap(
          config: config,
          isCancelled: () =>
              _shouldStop || widget.generationController.finishNowRequested,
          onStatusChanged: (status) {
            if (mounted) setState(() => _status = status);
          },
          onProgress: _handleBuildProgress,
        );

        if (_shouldStop && !widget.generationController.finishNowRequested) {
          if (mounted) {
            setState(
                () => _status = 'Build cancelled. ${tree.totalNodes} nodes.');
          }
          return;
        }
      } else {
        final bool skipBuild =
            existingTree != null && existingTree.maxPlyReached >= config.maxPly;

        if (skipBuild) {
          tree = existingTree;
          if (mounted) {
            setState(() => _status =
                'Tree already at depth ${existingTree.maxPlyReached}, '
                    'skipping build...');
          }
        } else {
          tree = await _buildService.build(
            config: config,
            isCancelled: () =>
                _shouldStop || widget.generationController.finishNowRequested,
            existingTree: existingTree,
            onProgress: _handleBuildProgress,
          );

          final finishingEarly = widget.generationController.finishNowRequested;
          if (finishingEarly) {
            widget.generationController.clearFinishNow();
            if (mounted) {
              setState(() =>
                  _status = 'Finishing early with ${tree.totalNodes} nodes...');
            }
          } else if (_shouldStop) {
            if (mounted) {
              setState(
                  () => _status = 'Build cancelled. ${tree.totalNodes} nodes.');
            }
            return;
          }
        }
      }

      if (mounted) setState(() => _status = 'Phase 2: Computing ease...');
      final easeCount = calculateTreeEase(tree);

      if (mounted) setState(() => _status = 'Phase 2: Computing expectimax...');
      final fenMap = FenMap()..populate(tree.root);
      final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
      final ecaCount = ecaCalc.calculate(tree);

      ecaCalc.computeTrapScores(tree.root);

      calculateMyEase(tree, playAsWhite: config.playAsWhite);

      if (mounted) {
        setState(() => _status = 'Phase 2: Selecting repertoire...');
      }
      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ecaCalc,
        fenMap: fenMap,
      );
      final selectedCount = selector.select(tree);

      // Re-sort children and rebuild metadata now that repertoire flags are set.
      tree.sortAllChildren();
      tree.computeMetadata();
      _applyKnownRootMoves(tree);

      if (mounted) setState(() => _status = 'Phase 3: Extracting lines...');
      final extractor = LineExtractor(config: config, fenMap: fenMap);
      var extractedLines = extractor.extract(tree);
      if (config.rankLinesByImportance) {
        extractedLines.sort((a, b) => b.probability.compareTo(a.probability));
      }
      _lines = extractedLines.length;

      widget.generationController.onTreeBuilt(tree);

      final rootFen = _rootFen();
      final rootWhiteToMove = _rootWhiteToMove(rootFen);
      for (int i = 0; i < extractedLines.length; i++) {
        final line = extractedLines[i];
        final idx = i + 1;
        final title = 'Generated Line $idx';
        final fullMoves = [...widget.currentMoveSequence, ...line.movesSan];
        final pgn = buildRepertoirePgnEntry(
          moves: fullMoves,
          title: title,
          cumulativeProb: line.probability,
          finalEvalCp: line.leafEvalCp ?? 0,
          isWhiteRepertoire: widget.isWhiteRepertoire,
          rootFen: rootFen,
          rootWhiteToMove: rootWhiteToMove,
          pruneReason: line.leafPruneReason,
          pruneEvalCp: line.leafPruneEvalCp,
          lineAnnotations: line.moveAnnotations,
          prefixMoveCount: widget.currentMoveSequence.length,
          rankByImportance: config.rankLinesByImportance,
          annotateMoveProbabilities: config.annotateMoveProbabilities,
          annotateMaiaOnly: config.annotateMaiaOnly,
        );
        _pgnWriter.queue(pgn);
        if (_pgnWriter.lineCount >= _pgnFlushEveryLines) {
          await _pgnWriter.flush(filePath);
        }
        widget.onLineSaved(fullMoves, title, pgn);
      }
      await _pgnWriter.flush(filePath);

      try {
        final treeJson = serializeTree(tree);
        final base = p.withoutExtension(filePath);
        await StorageFactory.instance.writeFile('${base}_tree.json', treeJson);
      } catch (_) {
        // Tree JSON save is best-effort
      }

      // Post-processing: extract and save trap lines (always write the file
      // so the UI can distinguish "never generated" from "no traps found").
      try {
        final trapExtractor = TrapExtractor(
          playAsWhite: config.playAsWhite,
        );
        final trapLines = trapExtractor.extract(tree);
        await TrapExtractor.saveToFile(trapLines, filePath);
      } catch (_) {
        // Trap extraction is best-effort
      }

      await _deletePartialTree();

      if (mounted) {
        setState(() {
          _status = 'Complete: ${tree.totalNodes} nodes, '
              '$selectedCount repertoire moves, '
              '$_lines lines. '
              '(ease=$easeCount, expectimax=$ecaCount)';
          _nodesPerMinute = null;
          _etaDepthSec = null;
        });
      }
    } catch (e) {
      final fp = widget.currentRepertoire?.filePath;
      if (fp != null && fp.isNotEmpty) {
        await _pgnWriter.flush(fp);
      }
      if (mounted) {
        setState(() => _status = 'Generation failed: $e');
      }
    } finally {
      if (engineGenerationEntered) {
        await EngineLifecycle().exitGeneration();
      }
      if (gen == _buildGeneration) {
        _isGenerating = false;
        widget.generationController.markGenerating(false);
        if (mounted) setState(() {});
      }
      _stopUiPulse();
      _checkForPartialTree();
    }
  }

  String _rootFen() {
    // The `[...currentMoveSequence, ...line.movesSan]` path is relative to
    // the app's standard startpos when currentMoveSequence is non-empty,
    // but to widget.fen otherwise (custom start with no prior moves).
    return widget.currentMoveSequence.isEmpty ? widget.fen : '';
  }

  bool _rootWhiteToMove(String rootFen) {
    if (rootFen.isEmpty) return true; // standard startpos
    final parts = rootFen.split(' ');
    return parts.length < 2 || parts[1] == 'w';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Generate Repertoire',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Starting position: ${widget.currentMoveSequence.isEmpty ? 'Initial position' : movesToPgnMoveText(widget.currentMoveSequence)}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          GenerationConfigForm(
            key: _configFormKey,
            isGenerating: _isGenerating,
            playAsWhite: widget.isWhiteRepertoire,
          ),
          const SizedBox(height: 8),
          if (_savedPartialTree != null && !_isGenerating) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warningSurface.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.pause_circle,
                          size: 18, color: AppColors.warning),
                      const SizedBox(width: 8),
                      Text(
                        'Paused Build Available',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_savedPartialTree!.totalNodes} nodes, '
                    'depth ${_savedPartialTree!.maxPlyReached}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () {
                          _configFormKey.currentState?.setMaxPly(
                            _savedPartialTree!.maxPlyReached,
                          );
                          _startTreeBuild(existingTree: _savedPartialTree!);
                        },
                        icon: const Icon(Icons.check),
                        label: const Text('Build Lines Now'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () =>
                            _startTreeBuild(existingTree: _savedPartialTree!),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Resume Build'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          _deletePartialTree();
                          setState(() => _savedPartialTree = null);
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Discard'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              FilledButton.icon(
                onPressed: _isGenerating ? null : _startTreeBuild,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Build Repertoire Tree'),
              ),
              if (_isGenerating && !_isPaused) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: togglePause,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.warningSurface,
                  ),
                  icon: const Icon(Icons.pause, color: Colors.white),
                  label: const Text(
                    'Pause',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              if (_isGenerating && _isPaused) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: togglePause,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.successSurface,
                  ),
                  icon: const Icon(Icons.play_arrow, color: Colors.white),
                  label: const Text(
                    'Resume',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => cancelGeneration(),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.dangerSurface,
                  ),
                  icon: const Icon(Icons.stop, color: Colors.white),
                  label: const Text(
                    'Cancel',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_isGenerating || _nodes > 0) ...[
            const SizedBox(height: 8),
            BuildProgressDisplay(
              nodes: _nodes,
              isGenerating: _isGenerating,
              isPaused: _isPaused,
              elapsedMs: _elapsedMs,
              nodesPerMinute: _nodesPerMinute,
              currentDepth: _currentDepth,
              maxPlyConfig: _maxPlyConfig,
              unexploredAtDepth: _unexploredAtDepth,
              totalAtDepth: _totalAtDepth,
              etaDepthSec: _etaDepthSec,
            ),
          ],
          const SizedBox(height: 8),
          Text(_status, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          Text(
            _configFormKey.currentState?.selectionModeDescription() ?? '',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  void _applyKnownRootMoves(BuildTree tree) {
    if (tree.startMoves.isNotEmpty ||
        widget.currentMoveSequence.isEmpty ||
        tree.root.fen != widget.fen) {
      return;
    }
    tree.startMoves = widget.currentMoveSequence.join(' ');
  }
}
