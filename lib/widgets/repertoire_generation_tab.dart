library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/build_tree_node.dart';
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

  // null = Maia only; non-null = override with that Lichess DB
  LichessDatabase? _lichessDbOverride;
  bool _relativeEval = false;
  bool _preferNovelties = false;

  // Lichess Players sub-options (shown when opponent source is lichessPlayers)
  final TextEditingController _lichessMinGamesCtrl =
      TextEditingController(text: '10');
  final Set<String> _lichessSpeeds = {'blitz', 'rapid', 'classical'};
  final Set<String> _lichessRatings = {'2000', '2200', '2500'};

  SelectionMode _selectionMode = SelectionMode.expectimax;
  bool _showAdvanced = false;
  bool _isGenerating = false;
  bool _cancelRequested = false;
  bool _isPaused = false;
  int _buildGeneration = 0;
  String _status = 'Idle';
  int _nodes = 0;
  int _lines = 0;
  int _ply = 0;
  int _engineCalls = 0;
  int _engineCacheHits = 0;
  int _maiaCalls = 0;
  int _lichessQueries = 0;
  int _elapsedMs = 0;
  DateTime _lastProgressUpdate = DateTime(0);
  final StringBuffer _pendingPgnBuffer = StringBuffer();
  int _pendingPgnLines = 0;
  BuildTree? _savedPartialTree;

  @override
  void initState() {
    super.initState();
    _minEvalCtrl = TextEditingController(
      text: widget.isWhiteRepertoire ? '0' : '-100',
    );
    _maxEvalCtrl = TextEditingController(
      text: widget.isWhiteRepertoire ? '200' : '100',
    );
    _checkForPartialTree();
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _maxPlyCtrl.dispose();
    _engineDepthCtrl.dispose();
    _evalGuardCtrl.dispose();
    _minEvalCtrl.dispose();
    _maxEvalCtrl.dispose();
    _maiaEloCtrl.dispose();
    _lichessMinGamesCtrl.dispose();
    _multipvCtrl.dispose();
    _oppMaxChildrenCtrl.dispose();
    _oppMassTargetCtrl.dispose();
    _leafConfidenceCtrl.dispose();
    super.dispose();
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
          setState(() => _savedPartialTree = tree);
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
      });
    }
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

  Future<void> _startTreeBuild({BuildTree? existingTree}) async {
    if (_isGenerating) return;
    final gen = ++_buildGeneration;
    final filePath = widget.currentRepertoire?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      setState(() => _status = 'Select a repertoire first.');
      return;
    }

    final TreeBuildConfig config;
    if (existingTree != null) {
      config = TreeBuildConfig.fromJson(
        existingTree.configSnapshot,
        startFen: existingTree.root.fen,
      );
    } else {
      config = TreeBuildConfig(
        startFen: widget.fen,
        playAsWhite: widget.isWhiteRepertoire,
        minProbability: _parsePercentToFraction(
          _cutoffCtrl.text,
          fallbackPercent: 0.01,
        ),
        maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 10,
        evalDepth: int.tryParse(_engineDepthCtrl.text.trim()) ?? 20,
        maxEvalLossCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 30,
        minEvalCp: int.tryParse(_minEvalCtrl.text.trim()) ??
            (widget.isWhiteRepertoire ? 0 : -100),
        maxEvalCp: int.tryParse(_maxEvalCtrl.text.trim()) ??
            (widget.isWhiteRepertoire ? 200 : 100),
        maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
        maiaOnly: _lichessDbOverride == null,
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
      _ply = existingTree?.maxPlyReached ?? 0;
      _engineCalls = 0;
      _engineCacheHits = 0;
      _maiaCalls = 0;
      _lichessQueries = 0;
      _elapsedMs = 0;
    });
    _pendingPgnBuffer.clear();
    _pendingPgnLines = 0;
    widget.onTreeReset?.call();
    widget.onGeneratingChanged(true);

    try {
      // Phase 1: Build tree
      final tree = await _buildService.build(
        config: config,
        isCancelled: () => _cancelRequested,
        existingTree: existingTree,
        onProgress: (p) {
          if (!mounted) return;
          _nodes = p.totalNodes;
          _ply = p.currentPly;
          _engineCalls = p.engineCalls;
          _engineCacheHits = p.engineCacheHits;
          _maiaCalls = p.maiaCalls;
          _lichessQueries = p.lichessQueries;
          _elapsedMs = p.elapsedMs;
          _status = 'Building: ${p.message}';

          final now = DateTime.now();
          if (now.difference(_lastProgressUpdate).inMilliseconds < 150) return;
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
      final extractedLines = extractor.extract(tree);
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
  }) {
    final date = DateTime.now().toIso8601String().split('T').first;
    final whiteName = widget.isWhiteRepertoire ? 'Repertoire' : 'Opponent';
    final blackName = widget.isWhiteRepertoire ? 'Opponent' : 'Repertoire';

    final rootFen = _rootFen();
    final rootWhiteToMove = _rootWhiteToMove(rootFen);
    final line = _movesToPgnMoveText(moves, rootWhiteToMove: rootWhiteToMove);

    final annotation = StringBuffer()
      ..write('{CumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%'
          ', Eval $finalEvalCp cp');
    if (pruneReason == PruneReason.evalTooHigh && pruneEvalCp != null) {
      annotation.write(
          ', Already winning (${pruneEvalCp >= 0 ? "+" : ""}${(pruneEvalCp / 100).toStringAsFixed(1)})');
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

  String _movesToPgnMoveText(List<String> moves,
      {bool rootWhiteToMove = true}) {
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
      sb.write(' ');
    }
    return sb.toString().trim();
  }

  // ── UI ─────────────────────────────────────────────────────────────────

  Widget _buildProgressDisplay() {
    final secs = _elapsedMs / 1000.0;
    final elapsed = secs >= 60
        ? '${(secs / 60).floor()}m ${(secs % 60).toStringAsFixed(0)}s'
        : '${secs.toStringAsFixed(1)}s';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              const Spacer(),
              Text(
                elapsed,
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _statChip('Lines', '$_lines'),
              _statChip('Ply', '$_ply'),
              _statChip('Eng', '$_engineCalls'),
              if (_engineCacheHits > 0)
                _statChip('Cached', '$_engineCacheHits'),
              if (_maiaCalls > 0) _statChip('Maia', '$_maiaCalls'),
              if (_lichessQueries > 0) _statChip('Lichess', '$_lichessQueries'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value) {
    return Text(
      '$label: $value',
      style: const TextStyle(fontSize: 13),
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

          // Main config fields
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_cutoffCtrl, 'Cum Prob Cutoff (%)'),
              _numField(_maxPlyCtrl, 'Max Ply'),
              _numField(_engineDepthCtrl, 'Engine Depth'),
              _numField(_evalGuardCtrl, 'Max Eval Loss (cp)'),
              _numField(_minEvalCtrl, 'Min Eval For Us (cp)'),
              _numField(_maxEvalCtrl, 'Max Eval For Us (cp)'),
              _numField(_maiaEloCtrl, 'Maia Elo'),
            ],
          ),
          const SizedBox(height: 8),

          // Opponent move source
          Row(
            children: [
              const Text('Opponent moves: Maia',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(width: 4),
              Tooltip(
                message:
                    'Maia neural network is the default opponent model.\n'
                    'You can override this with a Lichess database\n'
                    '(Players or Masters) in the Advanced section below.\n'
                    'When a Lichess DB is selected, Maia is still used\n'
                    'as a fallback for positions with no DB data.',
                child: Icon(Icons.info_outline,
                    size: 16, color: Colors.grey[500]),
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
                      : () => setState(
                          () => _lichessDbOverride = null),
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
                    : () => setState(
                        () => _preferNovelties = !_preferNovelties),
                child: const Text(
                  'Prefer novelties',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message:
                    'Favor less-played moves that are still sound.\n'
                    'Uses Maia/Lichess frequency data to boost unusual lines.',
                child: Icon(Icons.info_outline,
                    size: 16, color: Colors.grey[500]),
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
                      : (_) => setState(() =>
                          _lichessDbOverride ??= LichessDatabase.lichess),
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
                    'max ply ${_savedPartialTree!.maxPlyReached}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () =>
                            _startTreeBuild(existingTree: _savedPartialTree!),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Resume Build'),
                      ),
                      const SizedBox(width: 8),
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

  Widget _numField(TextEditingController controller, String label,
      {String? tooltip}) {
    final field = SizedBox(
      width: 170,
      child: TextField(
        controller: controller,
        enabled: !_isGenerating,
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
