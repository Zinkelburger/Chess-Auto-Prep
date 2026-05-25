library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/build_tree_node.dart';
import '../models/eval_database_settings.dart';
import '../services/eval/cdbdirect_eval_provider.dart';
import '../services/eval/chessdb_api_provider.dart';
import '../services/eval/sqlite_eval_provider.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/repertoire_selector.dart';
import '../services/generation/trap_extractor.dart';
import '../services/generation/tree_ease.dart';
import '../services/generation/tree_serialization.dart';
import '../services/coverage_service.dart';
import '../services/tree_build_service.dart';
import '../utils/system_info.dart';
import 'lichess_db_info_icon.dart';
import 'lichess_db_selector.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final Map<String, dynamic>? currentRepertoire;
  final List<String> currentMoveSequence;
  final void Function(bool generating) onGeneratingChanged;
  final void Function(bool paused) onPauseChanged;
  final void Function(List<String> moves, String title, String pgn) onLineSaved;
  final void Function(BuildTree tree)? onTreeBuilt;
  final VoidCallback? onTreeReset;

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.onGeneratingChanged,
    required this.onPauseChanged,
    required this.onLineSaved,
    this.onTreeBuilt,
    this.onTreeReset,
  });

  @override
  State<RepertoireGenerationTab> createState() =>
      RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  final TreeBuildService _buildService = TreeBuildService();

  static const int _pgnFlushEveryLines = 10;

  // ── Controllers ────────────────────────────────────────────────────────

  final TextEditingController _cutoffCtrl = TextEditingController(text: '0.01');
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '10');
  final TextEditingController _engineDepthCtrl =
      TextEditingController(text: '20');
  late final TextEditingController _engineThreadsCtrl;
  final TextEditingController _evalGuardCtrl =
      TextEditingController(text: '30');
  late final TextEditingController _minEvalCtrl;
  late final TextEditingController _maxEvalCtrl;
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2200');

  // Advanced
  final TextEditingController _multipvCtrl = TextEditingController(text: '5');
  final TextEditingController _oppMaxChildrenCtrl =
      TextEditingController(text: '6');
  final TextEditingController _oppMassTargetCtrl =
      TextEditingController(text: '0.95');
  final TextEditingController _leafConfidenceCtrl =
      TextEditingController(text: '1.0');

  // Eval sources (Advanced)
  bool _batchEvalLookups = false;
  bool _cdbDirectAvailable = false;
  bool _enableLocalChessDb = false;
  final TextEditingController _localChessDbPathCtrl = TextEditingController();
  bool? _localChessDbValid;
  bool _enableChessDbApi = false;
  final TextEditingController _chessDbQuotaCtrl =
      TextEditingController(text: '5000');
  final TextEditingController _chessDbConcurrencyCtrl =
      TextEditingController(text: '2');
  bool _enableExtEvalSubtreeSkip = true;
  final TextEditingController _minAcceptableEvalDepthCtrl =
      TextEditingController(text: '');
  int _chessDbApiUsedToday = 0;
  int _chessDbApiQuotaLimit = 5000;

  // null = Maia only; non-null = override with that Lichess DB
  LichessDatabase? _lichessDbOverride;
  bool _relativeEval = false;
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
  final StringBuffer _pendingPgnBuffer = StringBuffer();
  int _pendingPgnLines = 0;
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
    _refreshChessDbQuotaDisplay();
    EvalDatabaseSettings.instance.load();
    CdbDirectEvalProvider.probeAvailability().then((available) {
      if (!mounted) return;
      setState(() => _cdbDirectAvailable = available);
    });
  }

  Future<void> _refreshChessDbQuotaDisplay() async {
    final quota = int.tryParse(_chessDbQuotaCtrl.text.trim()) ?? 5000;
    final api = ChessDbApiProvider(dailyQuota: quota);
    await api.init();
    if (!mounted) return;
    setState(() {
      _chessDbApiUsedToday = api.usedToday;
      _chessDbApiQuotaLimit = api.quotaLimit;
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
    _multipvCtrl.dispose();
    _oppMaxChildrenCtrl.dispose();
    _oppMassTargetCtrl.dispose();
    _leafConfidenceCtrl.dispose();
    _chessDbQuotaCtrl.dispose();
    _chessDbConcurrencyCtrl.dispose();
    _minAcceptableEvalDepthCtrl.dispose();
    _localChessDbPathCtrl.dispose();
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
          _chessDbApiUsedToday = api.usedToday;
          _chessDbApiQuotaLimit = api.quotaLimit;
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
    final file = File(path);
    if (await file.exists()) {
      try {
        final json = await file.readAsString();
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
      } catch (_) {}
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
      await File(path).writeAsString(treeJson);
    } catch (_) {}
  }

  Future<void> _deletePartialTree() async {
    final path = _partialTreePath();
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void cancelGeneration({String? reason}) {
    if (!_isGenerating) return;
    _cancelRequested = true;
    _buildService.stopBuild();
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
    widget.onPauseChanged(false);
    widget.onGeneratingChanged(false);
    _checkForPartialTree();
  }

  void togglePause() {
    if (!_isGenerating) return;
    if (_isPaused) {
      _buildService.resumeBuild();
      setState(() {
        _isPaused = false;
        _status = 'Building: resumed...';
      });
      widget.onPauseChanged(false);
    } else {
      _buildService.pauseBuild();
      _savePartialTree();
      setState(() {
        _isPaused = true;
        _status = 'Paused ($_nodes nodes)';
      });
      widget.onPauseChanged(true);
    }
  }

  // ── Tree build generation ─────────────────────────────────────────────

  /// Current form values as a [TreeBuildConfig] (used for new builds and
  /// for [maxPly] when resuming a partial tree).
  TreeBuildConfig _treeBuildConfigFromControls() {
    final evalDepth = int.tryParse(_engineDepthCtrl.text.trim()) ?? 20;
    final rawThreads = int.tryParse(_engineThreadsCtrl.text.trim());
    final engineThreads = rawThreads != null
        ? clampEngineThreads(rawThreads)
        : defaultEngineThreads();
    final minAcceptableRaw = _minAcceptableEvalDepthCtrl.text.trim();
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
      maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 10,
      buildMode: _buildMode,
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
      ourMultipv: int.tryParse(_multipvCtrl.text.trim()) ?? 5,
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 6,
      oppMassTarget: double.tryParse(_oppMassTargetCtrl.text.trim()) ?? 0.95,
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
      batchEvalLookups: _cdbDirectAvailable && _batchEvalLookups,
      enableLocalChessDb: _enableLocalChessDb,
      localChessDbPath: _localChessDbPathCtrl.text.trim(),
      enableChessDbApi: _enableChessDbApi,
      chessDbApiDailyQuota:
          (int.tryParse(_chessDbQuotaCtrl.text.trim()) ?? 5000).clamp(1, 50000),
      chessDbApiConcurrency:
          (int.tryParse(_chessDbConcurrencyCtrl.text.trim()) ?? 2).clamp(1, 16),
      enableExtEvalSubtreeSkip: _enableExtEvalSubtreeSkip,
      minAcceptableEvalDepth: minAcceptableDepth,
    );
  }

  Future<void> _startTreeBuild({BuildTree? existingTree}) async {
    if (_isGenerating) return;
    if (_buildMode == BuildMode.dbExplorer ||
        _buildMode == BuildMode.trapFinder) {
      setState(() => _status =
          '${_buildModeLabel(_buildMode)} is not yet available in the app.');
      return;
    }
    if (_buildMode == BuildMode.maiaDbExplore &&
        !_enableLocalChessDb &&
        !_enableChessDbApi &&
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
      _chessDbApiQuotaLimit = config.chessDbApiDailyQuota;
      _chessDbApiUsedToday = 0;
    });
    _pendingPgnBuffer.clear();
    _pendingPgnLines = 0;
    widget.onTreeReset?.call();
    widget.onGeneratingChanged(true);
    _startUiPulse();

    try {
      // If the tree already reaches the target depth, skip Phase 1
      // entirely and use what we have — BFS guarantees shallower plies
      // are complete, so the tree is usable as-is.
      final bool skipBuild =
          existingTree != null && existingTree.maxPlyReached >= config.maxPly;

      final BuildTree tree;
      if (skipBuild) {
        tree = existingTree;
        if (mounted) {
          setState(() =>
              _status = 'Tree already at depth ${existingTree.maxPlyReached}, '
                  'skipping build...');
        }
      } else {
        // Phase 1: Build tree
        tree = await _buildService.build(
          config: config,
          isCancelled: () => _cancelRequested,
          existingTree: existingTree,
          onProgress: (p) {
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
          },
        );

        if (_cancelRequested) {
          if (mounted) {
            setState(
                () => _status = 'Build cancelled. ${tree.totalNodes} nodes.');
          }
          return;
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

      // Pass completed tree to parent for the eval-tree viewer
      widget.onTreeBuilt?.call(tree);

      // Save lines to PGN file
      for (int i = 0; i < extractedLines.length; i++) {
        final line = extractedLines[i];
        final idx = i + 1;
        final title = 'Generated Line $idx';
        final fullMoves = [...widget.currentMoveSequence, ...line.movesSan];
        final pgn = _buildPgnEntry(
          moves: fullMoves,
          title: title,
          cumulativeProb: line.probability,
          finalEvalCp: line.leafEvalCp ?? 0,
          pruneReason: line.leafPruneReason,
          pruneEvalCp: line.leafPruneEvalCp,
          lineAnnotations: line.moveAnnotations,
          prefixMoveCount: widget.currentMoveSequence.length,
          rankByImportance: config.rankLinesByImportance,
          annotateMoveProbabilities: config.annotateMoveProbabilities,
          annotateMaiaOnly: config.annotateMaiaOnly,
        );
        _queuePgnEntry(pgn);
        if (_pendingPgnLines >= _pgnFlushEveryLines) {
          await _flushPendingPgnWrites(filePath);
        }
        widget.onLineSaved(fullMoves, title, pgn);
      }
      await _flushPendingPgnWrites(filePath);

      // Save tree JSON alongside PGN
      try {
        final treeJson = serializeTree(tree);
        final base = p.withoutExtension(filePath);
        await File('${base}_tree.json').writeAsString(treeJson);
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
        await _flushPendingPgnWrites(fp);
      }
      if (mounted) {
        setState(() => _status = 'Generation failed: $e');
      }
    } finally {
      if (mounted && gen == _buildGeneration) {
        setState(() => _isGenerating = false);
        widget.onGeneratingChanged(false);
      }
      _stopUiPulse();
      _checkForPartialTree();
    }
  }

  // ── PGN helpers ───────────────────────────────────────────────────────

  void _queuePgnEntry(String pgn) {
    _pendingPgnBuffer.writeln();
    _pendingPgnBuffer.writeln(pgn);
    _pendingPgnLines++;
  }

  Future<void> _flushPendingPgnWrites(String filePath) async {
    if (_pendingPgnLines == 0) return;
    final payload = _pendingPgnBuffer.toString();
    _pendingPgnBuffer.clear();
    _pendingPgnLines = 0;
    await File(filePath).writeAsString(
      payload,
      mode: FileMode.append,
      flush: true,
    );
  }

  String _buildPgnEntry({
    required List<String> moves,
    required String title,
    required double cumulativeProb,
    required int finalEvalCp,
    PruneReason? pruneReason,
    int? pruneEvalCp,
    List<MoveProbabilityAnnotation> lineAnnotations = const [],
    int prefixMoveCount = 0,
    bool rankByImportance = true,
    bool annotateMoveProbabilities = true,
    bool annotateMaiaOnly = true,
  }) {
    final date = DateTime.now().toIso8601String().split('T').first;
    final whiteName = widget.isWhiteRepertoire ? 'Repertoire' : 'Opponent';
    final blackName = widget.isWhiteRepertoire ? 'Opponent' : 'Repertoire';

    final rootFen = _rootFen();
    final rootWhiteToMove = _rootWhiteToMove(rootFen);
    final line = _movesToPgnMoveText(
      moves,
      rootWhiteToMove: rootWhiteToMove,
      prefixMoveCount: prefixMoveCount,
      lineAnnotations: lineAnnotations,
      annotateMoveProbabilities: annotateMoveProbabilities,
      annotateMaiaOnly: annotateMaiaOnly,
    );

    final annotation = StringBuffer()
      ..write('{CumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%'
          ', Eval $finalEvalCp cp');
    if (pruneReason == PruneReason.evalTooHigh && pruneEvalCp != null) {
      annotation.write(
          ', Already winning (${pruneEvalCp >= 0 ? "+" : ""}${(pruneEvalCp / 100).toStringAsFixed(1)})');
    }
    if (rankByImportance) {
      annotation.write(
          ', [%importance ${cumulativeProb.toStringAsFixed(3)}]');
    }
    annotation.write('}');

    const standardStartpos =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final needsFenHeader = rootFen.isNotEmpty && rootFen != standardStartpos;

    final tags = [
      '[Event "$title"]',
      '[Date "$date"]',
      '[White "$whiteName"]',
      '[Black "$blackName"]',
      '[Result "*"]',
      '[Annotator "AutoGenerate"]',
      if (rankByImportance)
        '[Importance "${cumulativeProb.toStringAsFixed(3)}"]',
      if (needsFenHeader) '[FEN "$rootFen"]',
      if (needsFenHeader) '[SetUp "1"]',
    ];

    return [
      ...tags,
      '',
      '$annotation',
      '$line *',
    ].join('\n');
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

  String _movesToPgnMoveText(
    List<String> moves, {
    bool rootWhiteToMove = true,
    int prefixMoveCount = 0,
    List<MoveProbabilityAnnotation> lineAnnotations = const [],
    bool annotateMoveProbabilities = true,
    bool annotateMaiaOnly = true,
  }) {
    if (moves.isEmpty) return '';
    final sb = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      final ply = i + (rootWhiteToMove ? 0 : 1);
      if (ply.isEven) {
        sb.write('${(ply ~/ 2) + 1}. ');
      } else if (i == 0 && !rootWhiteToMove) {
        sb.write('${(ply ~/ 2) + 1}... ');
      }
      sb.write(moves[i]);

      if (annotateMoveProbabilities && i >= prefixMoveCount) {
        final annIdx = i - prefixMoveCount;
        if (annIdx < lineAnnotations.length &&
            lineAnnotations[annIdx].probability != null) {
          final ann = lineAnnotations[annIdx];
          final prob = ann.probability!;
          final tag = ann.fromLichess && !annotateMaiaOnly
              ? '[%humanFrequency ${prob.toStringAsFixed(3)}]'
              : '[%maiaProbability ${prob.toStringAsFixed(3)}]';
          sb.write(' {$tag}');
        }
      }
      sb.write(' ');
    }
    return sb.toString().trim();
  }

  // ── UI ─────────────────────────────────────────────────────────────────

  static String _formatEta(int sec) {
    if (sec < 60) return '${sec}s';
    if (sec < 3600) return '${(sec / 60).ceil()}m';
    final h = sec ~/ 3600;
    final m = ((sec % 3600) / 60).ceil();
    return '${h}h ${m}m';
  }

  Widget _buildProgressDisplay() {
    final secs = _elapsedMs / 1000.0;
    final elapsed = secs >= 60
        ? '${(secs / 60).floor()}m ${(secs % 60).toStringAsFixed(0)}s'
        : '${secs.toStringAsFixed(1)}s';

    final explored = _totalAtDepth - _unexploredAtDepth;
    final rateStr = _nodesPerMinute != null
        ? '${_nodesPerMinute!.toStringAsFixed(0)} nodes/min'
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: total nodes + elapsed
          Row(
            children: [
              if (_isGenerating && !_isPaused)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (_isPaused)
                Icon(Icons.pause_circle, size: 14, color: Colors.amber[400]),
              const SizedBox(width: 6),
              Text(
                '$_nodes nodes',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (rateStr != null) ...[
                const SizedBox(width: 10),
                Text(
                  rateStr,
                  style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                ),
              ],
              const Spacer(),
              Text(
                elapsed,
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              ),
            ],
          ),
          // Row 2: depth progress + ETA
          if (_isGenerating && _currentDepth > 0) ...[
            const SizedBox(height: 6),
            Text(
              () {
                final parts = <String>[
                  'Depth $_currentDepth/$_maxPlyConfig',
                  '$explored / $_totalAtDepth explored',
                  if (_unexploredAtDepth > 0) '$_unexploredAtDepth remaining',
                  if (_etaDepthSec != null) '~${_formatEta(_etaDepthSec!)}',
                ];
                return parts.join(' · ');
              }(),
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
          ],
        ],
      ),
    );
  }

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
            'Starting position: ${widget.currentMoveSequence.isEmpty ? 'Initial position' : _movesToPgnMoveText(widget.currentMoveSequence)}',
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
                child: Text('DB Explorer (coming soon)'),
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

          // Main config fields
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_cutoffCtrl, 'Cum Prob Cutoff (%)'),
              _numField(_maxPlyCtrl, 'Max Ply'),
              if (_buildMode == BuildMode.stockfishExpectimax) ...[
                _numField(_engineDepthCtrl, 'Engine Depth'),
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
            title: const Text('Rank lines by importance',
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
          if (_showAdvanced) ...[
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
                        'Shift the Min/Max Eval window relative to the root\n'
                        "position's engine eval instead of using absolute cp values."),
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
            _buildEvalSourcesSection(),
          ],
          const SizedBox(height: 8),

          // Saved partial tree banner
          if (_savedPartialTree != null && !_isGenerating) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber[700]!, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.pause_circle,
                          size: 18, color: Colors.amber[400]),
                      const SizedBox(width: 8),
                      Text(
                        'Paused Build Available',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.amber[300],
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
                    backgroundColor: Colors.amber[800],
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
                    backgroundColor: Colors.green[700],
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
                    backgroundColor: Colors.red[700],
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
            _buildProgressDisplay(),
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

  Future<void> _pickLocalChessDbFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select ChessDB SQLite file',
      type: FileType.custom,
      allowedExtensions: ['db'],
      lockParentWindow: true,
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final valid = await validateChessDbEvalFile(path);
    if (!mounted) return;
    setState(() {
      _localChessDbPathCtrl.text = path;
      _localChessDbValid = valid;
      if (valid) _enableLocalChessDb = true;
    });
  }

  Widget _buildEvalSourcesSection() {
    final localFieldsEnabled = _enableLocalChessDb && !_isGenerating;
    final apiFieldsEnabled = _enableChessDbApi && !_isGenerating;
    final path = _localChessDbPathCtrl.text;

    Widget? pathStatusIcon;
    if (path.isNotEmpty && _localChessDbValid != null) {
      pathStatusIcon = Tooltip(
        message: _localChessDbValid!
            ? 'Valid ChessDB database'
            : 'Not a valid ChessDB eval database (missing chessdb_evals table)',
        child: Icon(
          _localChessDbValid! ? Icons.check_circle : Icons.warning_amber,
          size: 18,
          color: _localChessDbValid! ? Colors.green[400] : Colors.red[400],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Eval Sources',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 4),
            Tooltip(
              message: _cdbDirectAvailable
                  ? 'Optional eval lookup chain before Stockfish:\n'
                      'project cache → cdbdirect full dump → local SQLite → API → engine.\n'
                      'On HDD, enable read-ahead and batch lookups for cdbdirect.'
                  : 'Optional eval lookup chain before Stockfish:\n'
                      'project cache → local SQLite → API → engine.',
              child: Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (_cdbDirectAvailable)
          ListenableBuilder(
            listenable: EvalDatabaseSettings.instance,
            builder: (context, _) {
              final dbSettings = EvalDatabaseSettings.instance;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  dbSettings.enableCdbDirect
                      ? Icons.storage
                      : Icons.storage_outlined,
                  color: dbSettings.enableCdbDirect
                      ? Colors.green[400]
                      : Colors.grey,
                ),
                title: const Text('Local ChessDB (full dump)',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  dbSettings.enableCdbDirect &&
                          dbSettings.cdbDirectPath.isNotEmpty
                      ? dbSettings.cdbDirectPath
                      : 'Configure in Actions → Database Downloads',
                  style: const TextStyle(fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                dense: true,
              );
            },
          ),
        if (_cdbDirectAvailable)
          Wrap(
            spacing: 16,
            children: [
              FilterChip(
                label: const Text('Batch eval lookups'),
                selected: _batchEvalLookups,
                onSelected: _isGenerating
                    ? null
                    : (v) => setState(() => _batchEvalLookups = v),
              ),
            ],
          ),
        if (_cdbDirectAvailable) const SizedBox(height: 12),

        // Local ChessDB SQLite slice
        _toggleSwitch(
          'Local ChessDB file',
          _enableLocalChessDb,
          (v) => setState(() => _enableLocalChessDb = v),
          tooltip:
              'Use a local ChessDB SQLite slice for eval lookups.\n'
              'Positions missing from the file can trigger subtree skip.',
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                readOnly: true,
                enabled: !_isGenerating,
                controller: _localChessDbPathCtrl,
                decoration: InputDecoration(
                  labelText: 'Database path (.db)',
                  hintText: 'No file selected',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: pathStatusIcon,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Browse for a ChessDB .db file',
              child: IconButton(
                onPressed: localFieldsEnabled ? _pickLocalChessDbFile : null,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            if (path.isNotEmpty)
              Tooltip(
                message: 'Clear path',
                child: IconButton(
                  onPressed: _isGenerating
                      ? null
                      : () => setState(() {
                            _localChessDbPathCtrl.clear();
                            _localChessDbValid = null;
                          }),
                  icon: const Icon(Icons.clear),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // ChessDB API
        _toggleSwitch(
          'ChessDB API',
          _enableChessDbApi,
          (v) => setState(() => _enableChessDbApi = v),
          tooltip:
              'Query chessdb.cn for positions not in local cache.\n'
              'Subject to a configurable daily request quota.',
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _numField(
              _chessDbQuotaCtrl,
              'Daily quota',
              tooltip: 'Maximum ChessDB API requests per day (1–50000)',
              enabled: apiFieldsEnabled,
            ),
            _numField(
              _chessDbConcurrencyCtrl,
              'Concurrency',
              tooltip: 'Parallel ChessDB API requests during build (1–16)',
              enabled: apiFieldsEnabled,
            ),
            Text(
              '$_chessDbApiUsedToday / $_chessDbApiQuotaLimit requests used today',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Behavior settings
        _toggleSwitch(
          'Skip external eval for off-book subtrees',
          _enableExtEvalSubtreeSkip,
          (v) => setState(() => _enableExtEvalSubtreeSkip = v),
          tooltip:
              'When a position is absent from the local ChessDB file,\n'
              'skip further external lookups for that subtree and use Stockfish.',
        ),
        const SizedBox(height: 8),
        _numField(
          _minAcceptableEvalDepthCtrl,
          'Min eval depth (0 = engine depth)',
          tooltip:
              'Minimum search depth required from external sources.\n'
              'Shallower hits fall through to the next source.',
          enabled: !_isGenerating,
        ),
      ],
    );
  }

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
        return 'Walk the tree using only ChessDB move rankings and scores '
            '(queryall). No engine, no Maia — pure database-guided exploration.';
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
