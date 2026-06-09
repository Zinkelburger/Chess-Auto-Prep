library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../constants/engine_defaults.dart';
import '../models/build_tree_node.dart';
import '../models/eval_database_settings.dart';
import '../services/storage/storage_factory.dart';
import '../services/eval/cdbdirect_eval_provider.dart';
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
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/tree_build_service.dart';
import '../core/generation_session_controller.dart';
import '../utils/system_info.dart';
import 'lichess_db_info_icon.dart';
import '../theme/app_colors.dart';
import 'generation/build_progress_display.dart';
import 'lichess_db_selector.dart';
import 'generation/eval_sources_section.dart';
import 'pgn_sources_panel.dart';
import '../models/pgn_source.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final Map<String, dynamic>? currentRepertoire;
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
  TreeBuildService get _buildService => widget.generationController.buildService;
  final GlobalKey<EvalSourcesSectionState> _evalSourcesKey =
      GlobalKey<EvalSourcesSectionState>();
  bool _cdbDirectAvailable = false;

  static const int _pgnFlushEveryLines = 10;

  // ── Controllers ────────────────────────────────────────────────────────

  final TextEditingController _cutoffCtrl = TextEditingController(text: '0.01');
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '20');
  final TextEditingController _engineDepthCtrl = TextEditingController(
    text: '$kDefaultGenerationEvalDepth',
  );
  late final TextEditingController _engineThreadsCtrl;
  final TextEditingController _evalGuardCtrl =
      TextEditingController(text: '30');
  late final TextEditingController _minEvalCtrl;
  late final TextEditingController _maxEvalCtrl;
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2200');

  // Advanced
  final TextEditingController _multipvCtrl = TextEditingController(text: '4');
  final TextEditingController _oppMaxChildrenCtrl =
      TextEditingController(text: '4');
  final TextEditingController _oppMassTargetCtrl =
      TextEditingController(text: '0.80');
  final TextEditingController _leafConfidenceCtrl =
      TextEditingController(text: '1.0');

  // ── DB Explorer state ──
  final GlobalKey<PgnSourcesPanelState> _pgnSourcesKey =
      GlobalKey<PgnSourcesPanelState>();
  final List<String> _pgnFilePaths = [];
  final TextEditingController _dbMinGamesCtrl =
      TextEditingController(text: '5');
  final TextEditingController _dbMinProbCtrl =
      TextEditingController(text: '0.05');
  final TextEditingController _minEloCtrl =
      TextEditingController(text: '0');

  // null = Maia only; non-null = override with that Lichess DB
  LichessDatabase? _lichessDbOverride;
  bool _relativeEval = true;
  bool _preferNovelties = false;

  // PGN export options
  bool _rankLinesByImportance = true;
  bool _annotateMoveProbabilities = true;
  bool _annotateMaiaOnly = true;

  // Lichess Players sub-options (shown when opponent source is lichessPlayers)
  final TextEditingController _lichessMinGamesCtrl =
      TextEditingController(text: '10');
  final Set<String> _lichessSpeeds = {'blitz', 'rapid', 'classical'};
  final Set<String> _lichessRatings = {'2000', '2200', '2500'};

  SelectionMode _selectionMode = SelectionMode.expectimax;
  BuildMode _buildMode = BuildMode.stockfishExpectimax;
  bool _showAdvanced = false;
  bool _isGenerating = false;
  bool _cancelRequested = false;
  bool _isPaused = false;
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
    _engineThreadsCtrl = TextEditingController(
      text: defaultEngineThreads().toString(),
    );
    _minEvalCtrl = TextEditingController(
      text: widget.isWhiteRepertoire ? '0' : '-100',
    );
    _maxEvalCtrl = TextEditingController(
      text: widget.isWhiteRepertoire ? '200' : '100',
    );
    _checkForPartialTree();
    CdbDirectEvalProvider.probeAvailability().then((available) {
      if (!mounted) return;
      setState(() => _cdbDirectAvailable = available);
    });
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
    setState(() {
      _buildMode = BuildMode.dbExplorer;
      _pgnFilePaths
        ..clear()
        ..addAll(pgnPaths);
      _dbMinGamesCtrl.text = minGames.toString();
    });
    // Also seed the PgnSourcesPanel if mounted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final panelState = _pgnSourcesKey.currentState;
      if (panelState != null) {
        final sources = pgnPaths
            .map((path) => PgnSource(
                  id: PgnSource.generateId(),
                  name: p.basenameWithoutExtension(path),
                  filePath: path,
                ))
            .toList();
        panelState.seedSources(sources);
      }
      if (autoStart && mounted && !_isGenerating) _startTreeBuild();
    });
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _maxPlyCtrl.dispose();
    _engineDepthCtrl.dispose();
    _engineThreadsCtrl.dispose();
    _evalGuardCtrl.dispose();
    _minEvalCtrl.dispose();
    _maxEvalCtrl.dispose();
    _maiaEloCtrl.dispose();
    _lichessMinGamesCtrl.dispose();
    _dbMinGamesCtrl.dispose();
    _dbMinProbCtrl.dispose();
    _minEloCtrl.dispose();
    _multipvCtrl.dispose();
    _oppMaxChildrenCtrl.dispose();
    _oppMassTargetCtrl.dispose();
    _leafConfidenceCtrl.dispose();
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
          _evalSourcesKey.currentState?.updateChessDbApiUsage(
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
    final oldPath = oldWidget.currentRepertoire?['filePath'] as String?;
    final newPath = widget.currentRepertoire?['filePath'] as String?;
    if (oldPath != newPath) {
      _savedPartialTree = null;
      _checkForPartialTree();
    }
  }

  String? _partialTreePath() {
    final filePath = widget.currentRepertoire?['filePath'] as String?;
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
              _maxPlyCtrl.text = md.toInt().toString();
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
      _savePartialTree();
      setState(() {
        _isPaused = true;
        _status = 'Paused ($_nodes nodes)';
      });
    }
  }

  // ── Tree build generation ─────────────────────────────────────────────

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

    final now = DateTime.now();
    if (now.difference(_lastProgressUpdate).inMilliseconds < 150) {
      return;
    }
    _lastProgressUpdate = now;
    setState(() {});
  }

  /// Current form values as a [TreeBuildConfig] (used for new builds and
  /// for [maxPly] when resuming a partial tree).
  TreeBuildConfig _treeBuildConfigFromControls() {
    final evalDepth =
        int.tryParse(_engineDepthCtrl.text.trim()) ??
            kDefaultGenerationEvalDepth;
    final rawThreads = int.tryParse(_engineThreadsCtrl.text.trim());
    final engineThreads = rawThreads != null
        ? clampEngineThreads(rawThreads)
        : defaultEngineThreads();
    final eval = _evalSourcesKey.currentState;
    final minAcceptableRaw = eval?.minAcceptableEvalDepthRaw ?? '';
    final minAcceptableDepth = minAcceptableRaw.isEmpty
        ? 0
        : (int.tryParse(minAcceptableRaw) ?? evalDepth);

    final dbSettings = EvalDatabaseSettings.instance;

    return TreeBuildConfig(
      startFen: widget.fen,
      playAsWhite: widget.isWhiteRepertoire,
      minProbability: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: 0.01,
      ),
      maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 20,
      buildMode: _buildMode,
      pgnFilePaths: List.unmodifiable(_pgnFilePaths),
      dbMinGames: int.tryParse(_dbMinGamesCtrl.text.trim()) ?? 5,
      dbMinProb: double.tryParse(_dbMinProbCtrl.text.trim()) ?? 0.05,
      minElo: int.tryParse(_minEloCtrl.text.trim()) ?? 0,
      evalDepth: evalDepth,
      engineThreads: engineThreads,
      maxEvalLossCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 30,
      minEvalCp: int.tryParse(_minEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 0 : -100),
      maxEvalCp: int.tryParse(_maxEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 200 : 100),
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
      maiaOnly: _lichessDbOverride == null,
      rankLinesByImportance: _rankLinesByImportance,
      annotateMoveProbabilities: _annotateMoveProbabilities,
      annotateMaiaOnly: _annotateMaiaOnly,
      ourMultipv: int.tryParse(_multipvCtrl.text.trim()) ?? 4,
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 4,
      oppMassTarget: double.tryParse(_oppMassTargetCtrl.text.trim()) ?? 0.80,
      useLichessDb: _lichessDbOverride != null,
      useMasters: _lichessDbOverride == LichessDatabase.masters,
      speeds: _lichessSpeeds.join(','),
      ratingRange: (_lichessRatings.toList()..sort()).join(','),
      minGames: int.tryParse(_lichessMinGamesCtrl.text.trim()) ?? 10,
      relativeEval: _relativeEval,
      selectionMode: _selectionMode,
      noveltyWeight: _preferNovelties ? 60 : 0,
      leafConfidence: double.tryParse(_leafConfidenceCtrl.text.trim()) ?? 1.0,
      enableCdbDirect:
          _cdbDirectAvailable && dbSettings.enableCdbDirect,
      cdbDirectPath:
          _cdbDirectAvailable ? dbSettings.cdbDirectPath : '',
      cdbDirectReadAhead:
          _cdbDirectAvailable && dbSettings.cdbDirectReadAhead,
      batchEvalLookups:
          _cdbDirectAvailable && (eval?.batchEvalLookups ?? false),
      enableLocalChessDb: eval?.enableLocalChessDb ?? false,
      localChessDbPath: eval?.localChessDbPath ?? '',
      enableChessDbApi: eval?.enableChessDbApi ?? false,
      chessDbApiDailyQuota: eval?.chessDbApiDailyQuota ?? 5000,
      chessDbApiConcurrency: eval?.chessDbApiConcurrency ?? 2,
      enableExtEvalSubtreeSkip: eval?.enableExtEvalSubtreeSkip ?? true,
      minAcceptableEvalDepth: minAcceptableDepth,
    );
  }

  Future<void> _startTreeBuild({BuildTree? existingTree}) async {
    if (_isGenerating) return;
    if (_buildMode == BuildMode.trapFinder) {
      setState(() => _status =
          '${_buildModeLabel(_buildMode)} is not yet available in the app.');
      return;
    }
    if (_buildMode == BuildMode.dbExplorer && _pgnFilePaths.isEmpty) {
      final sources = _pgnSourcesKey.currentState?.sources ?? [];
      if (sources.isEmpty) {
        setState(() => _status = 'Add at least one PGN file for DB Explorer.');
        return;
      }
    }
    final evalSources = _evalSourcesKey.currentState;
    if (_buildMode == BuildMode.maiaDbExplore &&
        !(evalSources?.enableLocalChessDb ?? false) &&
        !(evalSources?.enableChessDbApi ?? false) &&
        !EvalDatabaseSettings.instance.enableCdbDirect) {
      setState(() => _status =
          'Maia + DB mode needs at least one eval source enabled '
          '(local ChessDB, cdbdirect, or ChessDB API).');
      return;
    }
    final gen = ++_buildGeneration;
    final filePath = widget.currentRepertoire?['filePath'] as String?;
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
      final ui = _treeBuildConfigFromControls();
      config = saved.copyWith(maxPly: ui.maxPly);
      existingTree.configSnapshot = Map<String, dynamic>.from(config.toJson());
    } else {
      config = _treeBuildConfigFromControls();
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
      _evalSourcesKey.currentState
          ?.resetChessDbApiUsageForBuild(config.chessDbApiDailyQuota);

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
        // DB Explorer: PGN parse → freq map → BFS → eval enrichment
        tree = await _buildService.buildFromPgnFreqMap(
          config: config,
          isCancelled: () => _cancelRequested,
          onStatusChanged: (status) {
            if (mounted) setState(() => _status = status);
          },
          onProgress: _handleBuildProgress,
        );

        if (_cancelRequested) {
          if (mounted) {
            setState(
                () => _status = 'Build cancelled. ${tree.totalNodes} nodes.');
          }
          return;
        }
      } else {
        // Standard build modes (Stockfish/Maia)
        final bool skipBuild =
            existingTree != null && existingTree.maxPlyReached >= config.maxPly;

        if (skipBuild) {
          tree = existingTree;
          if (mounted) {
            setState(() =>
                _status = 'Tree already at depth ${existingTree.maxPlyReached}, '
                    'skipping build...');
          }
        } else {
          tree = await _buildService.build(
            config: config,
            isCancelled: () => _cancelRequested,
            existingTree: existingTree,
            onProgress: _handleBuildProgress,
          );

          if (_cancelRequested) {
            if (mounted) {
              setState(
                  () => _status = 'Build cancelled. ${tree.totalNodes} nodes.');
            }
            return;
          }
        }
      }

      // Phase 2a: Ease
      if (mounted) setState(() => _status = 'Phase 2: Computing ease...');
      final easeCount = calculateTreeEase(tree);

      // Phase 2b: Expectimax
      if (mounted) setState(() => _status = 'Phase 2: Computing expectimax...');
      final fenMap = FenMap()..populate(tree.root);
      final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
      final ecaCount = ecaCalc.calculate(tree);

      // Phase 2b.2: Trap scores
      ecaCalc.computeTrapScores(tree.root);

      // Phase 2b.3: My Ease (how natural our moves are)
      calculateMyEase(tree, playAsWhite: config.playAsWhite);

      // Phase 2c: Select repertoire moves
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

      // Phase 3: Extract lines
      if (mounted) setState(() => _status = 'Phase 3: Extracting lines...');
      final extractor = LineExtractor(config: config, fenMap: fenMap);
      var extractedLines = extractor.extract(tree);
      if (config.rankLinesByImportance) {
        extractedLines.sort((a, b) => b.probability.compareTo(a.probability));
      }
      _lines = extractedLines.length;

      widget.generationController.onTreeBuilt(tree);

      // Save lines to PGN file
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

      // Save tree JSON alongside PGN
      try {
        final treeJson = serializeTree(tree);
        final base = p.withoutExtension(filePath);
        await StorageFactory.instance
            .writeFile('${base}_tree.json', treeJson);
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
      final fp = widget.currentRepertoire?['filePath'] as String?;
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
      if (mounted && gen == _buildGeneration) {
        setState(() => _isGenerating = false);
        widget.generationController.markGenerating(false);
      }
      _stopUiPulse();
      _checkForPartialTree();
    }
  }

  // ── PGN helpers ───────────────────────────────────────────────────────

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

  // ── UI ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Auto Repertoire Generation',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Starting position: ${widget.currentMoveSequence.isEmpty ? 'Initial position' : movesToPgnMoveText(widget.currentMoveSequence)}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),

          // Build algorithm mode
          DropdownButtonFormField<BuildMode>(
            value: _buildMode,
            decoration: const InputDecoration(
              labelText: 'Build Algorithm',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(
                value: BuildMode.stockfishExpectimax,
                child: Text('Stockfish + Expectimax (default)'),
              ),
              DropdownMenuItem(
                value: BuildMode.maiaDbExplore,
                child: Text('Maia + DB (fast, no engine)'),
              ),
              DropdownMenuItem(
                value: BuildMode.dbExplorer,
                child: Text('DB Explorer (PGN database)'),
              ),
              DropdownMenuItem(
                value: BuildMode.trapFinder,
                child: Text('Trap / Interest Finder (coming soon)'),
              ),
            ],
            onChanged: _isGenerating
                ? null
                : (v) {
                    if (v != null) setState(() => _buildMode = v);
                  },
          ),
          const SizedBox(height: 4),
          Text(
            _buildModeDescription(),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),

          // DB Explorer: PGN sources panel
          if (_buildMode == BuildMode.dbExplorer) ...[
            PgnSourcesPanel(
              key: _pgnSourcesKey,
              initialSources: null,
              onSourcesChanged: (sources) {
                // Keep _pgnFilePaths in sync for TreeBuildConfig compatibility
                _pgnFilePaths
                  ..clear()
                  ..addAll(sources
                      .where((s) => s.filePath != null)
                      .map((s) => s.filePath!));
              },
            ),
            const SizedBox(height: 8),
          ],

          // Main config fields
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_cutoffCtrl, 'Cum Prob Cutoff (%)'),
              _numField(_maxPlyCtrl, 'Max Ply'),
              if (_buildMode == BuildMode.stockfishExpectimax) ...[
                _numField(
                  _engineDepthCtrl,
                  'Engine Depth (tree build)',
                  tooltip:
                      'Stockfish search depth during repertoire tree '
                      'generation (Phase 1). Separate from on-the-fly '
                      'expectimax in Settings → On-the-fly Expectimax.',
                ),
                _numField(
                  _engineThreadsCtrl,
                  'Engine Threads',
                  tooltip:
                      'Stockfish UCI threads per worker during tree build '
                      '(1–${getLogicalCores()}). MultiPV is much faster '
                      'with multiple threads.',
                ),
              ],
              _numField(_evalGuardCtrl, 'Max Eval Loss (cp)'),
              _numField(_minEvalCtrl, 'Min Eval For Us (cp)'),
              _numField(_maxEvalCtrl, 'Max Eval For Us (cp)'),
              _numField(_maiaEloCtrl, 'Maia Elo'),
            ],
          ),
          const SizedBox(height: 8),

          // PGN export options
          Text('PGN export',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Rank lines by cumulative probability',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              'Sort lines by cumulative probability (most likely first).',
              style: TextStyle(fontSize: 12),
            ),
            value: _rankLinesByImportance,
            onChanged: _isGenerating
                ? null
                : (v) => setState(() => _rankLinesByImportance = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Annotate move probabilities',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              'Add [%maiaProbability] / [%humanFrequency] on opponent moves.',
              style: TextStyle(fontSize: 12),
            ),
            value: _annotateMoveProbabilities,
            onChanged: _isGenerating
                ? null
                : (v) => setState(() => _annotateMoveProbabilities = v),
          ),
          if (_annotateMoveProbabilities)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8),
              child: DropdownButtonFormField<bool>(
                value: _annotateMaiaOnly,
                decoration: const InputDecoration(
                  labelText: 'Probability source',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: true,
                    child: Text('Maia only'),
                  ),
                  DropdownMenuItem(
                    value: false,
                    child: Text('Lichess DB + Maia fallback'),
                  ),
                ],
                onChanged: _isGenerating
                    ? null
                    : (v) {
                        if (v != null) setState(() => _annotateMaiaOnly = v);
                      },
              ),
            ),

          // Opponent move source
          Row(
            children: [
              const Text('Opponent moves: Maia',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(width: 4),
              Tooltip(
                message: 'Maia neural network is the default opponent model.\n'
                    'You can override this with a Lichess database\n'
                    '(Players or Masters) in the Advanced section below.\n'
                    'When a Lichess DB is selected, Maia is still used\n'
                    'as a fallback for positions with no DB data.',
                child:
                    Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
              ),
              if (_lichessDbOverride != null) ...[
                const SizedBox(width: 8),
                Chip(
                  label: Text(
                    _lichessDbOverride == LichessDatabase.masters
                        ? 'Overridden: Lichess Masters'
                        : 'Overridden: Lichess Players',
                    style: const TextStyle(fontSize: 11),
                  ),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: _isGenerating
                      ? null
                      : () => setState(() => _lichessDbOverride = null),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),

          // Prefer novelties
          Row(
            children: [
              Checkbox(
                value: _preferNovelties,
                onChanged: _isGenerating
                    ? null
                    : (v) => setState(() => _preferNovelties = v ?? false),
              ),
              GestureDetector(
                onTap: _isGenerating
                    ? null
                    : () =>
                        setState(() => _preferNovelties = !_preferNovelties),
                child: const Text(
                  'Prefer novelties',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: 'Favor less-played moves that are still sound.\n'
                    'Uses Maia/Lichess frequency data to boost unusual lines.',
                child:
                    Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Selection mode
          DropdownButtonFormField<SelectionMode>(
            value: _selectionMode,
            decoration: const InputDecoration(
              labelText: 'Selection Mode',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(
                value: SelectionMode.expectimax,
                child: Text('Expectimax (Stockfish + Maia)'),
              ),
              DropdownMenuItem(
                value: SelectionMode.engineOnly,
                child: Text('Engine only (best Stockfish eval)'),
              ),
              DropdownMenuItem(
                value: SelectionMode.dbWinRateOnly,
                child: Text('DB win rate only (no engine selection)'),
              ),
              DropdownMenuItem(
                value: SelectionMode.playable,
                child: Text('Playable (expectimax + ease)'),
              ),
            ],
            onChanged: _isGenerating
                ? null
                : (v) {
                    if (v != null) setState(() => _selectionMode = v);
                  },
          ),
          const SizedBox(height: 4),

          // Advanced section
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
                const SizedBox(width: 4),
                const Text('Advanced', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          Visibility(
            visible: _showAdvanced,
            maintainState: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _numField(_multipvCtrl, 'MultiPV',
                    tooltip: 'Candidate moves evaluated per our-move node'),
                _numField(_oppMaxChildrenCtrl, 'Opp Max Children',
                    tooltip: 'Maximum opponent replies explored per position'),
                _numField(_oppMassTargetCtrl, 'Opp Mass Target',
                    tooltip:
                        'Stop adding opponent moves after this probability mass is covered'),
                _numField(_leafConfidenceCtrl, 'Leaf Confidence (0-1)',
                    tooltip:
                        'Trust in engine eval at leaves; lower blends toward 0.5'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _toggleSwitch('Relative Eval', _relativeEval, (v) {
                  setState(() => _relativeEval = v);
                },
                    tooltip:
                        'Thresholds are relative to the root eval (default).\n'
                        'Turn off to use absolute centipawn limits from Min/Max Eval.'),
                const LichessDbInfoIcon(size: 14),
              ],
            ),
            const SizedBox(height: 12),

            // Lichess DB override
            Row(
              children: [
                const Text('Opponent DB override',
                    style: TextStyle(fontSize: 13)),
                const SizedBox(width: 4),
                Tooltip(
                  message:
                      'Override Maia with a Lichess database for opponent\n'
                      'move frequencies. Maia remains the fallback for\n'
                      'positions with no database data.',
                  child: Icon(Icons.info_outline,
                      size: 16, color: Colors.grey[500]),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('None (Maia only)'),
                  selected: _lichessDbOverride == null,
                  onSelected: _isGenerating
                      ? null
                      : (_) => setState(() => _lichessDbOverride = null),
                ),
                const SizedBox(width: 4),
                ChoiceChip(
                  label: const Text('Lichess DB'),
                  selected: _lichessDbOverride != null,
                  onSelected: _isGenerating
                      ? null
                      : (_) => setState(
                          () => _lichessDbOverride ??= LichessDatabase.lichess),
                ),
              ],
            ),
            if (_lichessDbOverride != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: LichessDbSelector(
                  database: _lichessDbOverride!,
                  onDatabaseChanged: (db) => setState(() {
                    final wasMasters =
                        _lichessDbOverride == LichessDatabase.masters;
                    final isMasters = db == LichessDatabase.masters;
                    _lichessDbOverride = db;
                    if (wasMasters != isMasters) {
                      _lichessMinGamesCtrl.text = isMasters ? '4' : '10';
                    }
                  }),
                  selectedSpeeds: _lichessSpeeds,
                  onSpeedsChanged: (s) => setState(() {
                    _lichessSpeeds
                      ..clear()
                      ..addAll(s);
                  }),
                  selectedRatings: _lichessRatings,
                  onRatingsChanged: (r) => setState(() {
                    _lichessRatings
                      ..clear()
                      ..addAll(r);
                  }),
                  minGamesController: _lichessMinGamesCtrl,
                  enabled: !_isGenerating,
                  compact: true,
                ),
              ),
            ],
            const SizedBox(height: 16),
            EvalSourcesSection(
              key: _evalSourcesKey,
              isGenerating: _isGenerating,
              cdbDirectAvailable: _cdbDirectAvailable,
            ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Saved partial tree banner
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
                          _maxPlyCtrl.text =
                              _savedPartialTree!.maxPlyReached.toString();
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

          // Action buttons
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
            _selectionModeDescription(),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _numField(
    TextEditingController controller,
    String label, {
    String? tooltip,
    bool enabled = true,
  }) {
    final field = SizedBox(
      width: 170,
      child: TextField(
        controller: controller,
        enabled: enabled && !_isGenerating,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip, child: field);
  }

  Widget _toggleSwitch(String label, bool value, ValueChanged<bool> onChanged,
      {String? tooltip}) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        Switch(
          value: value,
          onChanged: _isGenerating ? null : onChanged,
        ),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip, child: row);
  }

  // ── DB Explorer file picker (legacy — now uses PgnSourcesPanel) ─────

  String _buildModeLabel(BuildMode mode) {
    switch (mode) {
      case BuildMode.stockfishExpectimax:
        return 'Stockfish + Expectimax';
      case BuildMode.maiaDbExplore:
        return 'Maia + DB';
      case BuildMode.dbExplorer:
        return 'DB Explorer';
      case BuildMode.trapFinder:
        return 'Trap / Interest Finder';
    }
  }

  String _buildModeDescription() {
    switch (_buildMode) {
      case BuildMode.stockfishExpectimax:
        return 'Full repertoire build: Stockfish MultiPV for our moves, '
            'Maia/Lichess for opponent replies, expectimax selection. '
            'Most thorough; needs a capable CPU.';
      case BuildMode.maiaDbExplore:
        return 'Fast exploration without Stockfish: top Maia moves for our '
            'side, database evals only. Branches stop when a position is '
            'missing from the database — natural pruning by DB coverage.';
      case BuildMode.dbExplorer:
        return 'Build a tree from PGN game databases: parse files into a '
            'frequency map, then BFS-expand using actual game statistics. '
            'Evals are enriched from DB sources + Stockfish after the tree '
            'is built.';
      case BuildMode.trapFinder:
        return 'Surface positions where human-likely moves (Maia) lead to '
            'bad database evals — a highlights reel of tactical moments, '
            'not a full repertoire.';
    }
  }

  String _selectionModeDescription() {
    switch (_selectionMode) {
      case SelectionMode.expectimax:
        return 'Two-phase: builds the full tree with constant MultiPV at each ply'
            ' + single-source opponent moves, then computes expectimax'
            ' and selects repertoire lines.';
      case SelectionMode.engineOnly:
        return 'Builds the full tree, then selects moves purely by engine eval.'
            ' Ignores opponent frequency / win-rate data for selection.';
      case SelectionMode.dbWinRateOnly:
        return 'Builds the full tree, then selects moves by database win rate.'
            ' Falls back to engine eval when no DB data is available.';
      case SelectionMode.playable:
        return 'Blends expectimax value (60%) with my-ease (40%) to prefer'
            ' moves that are both strong and natural for a human to find.';
    }
  }

  double _parsePercentToFraction(
    String raw, {
    required double fallbackPercent,
  }) {
    final parsed = double.tryParse(raw.replaceAll('%', '').trim());
    final safePercent = (parsed ?? fallbackPercent).clamp(0.0, 100.0);
    return safePercent / 100.0;
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
