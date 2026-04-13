library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/build_tree_node.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/line_extractor.dart';
import '../services/generation/repertoire_selector.dart';
import '../services/generation/tree_ease.dart';
import '../services/generation/tree_serialization.dart';
import '../services/repertoire_generation_service.dart';
import '../services/tree_build_service.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final Map<String, dynamic>? currentRepertoire;
  final List<String> currentMoveSequence;
  final void Function(bool generating) onGeneratingChanged;
  final void Function(List<String> moves, String title, String pgn) onLineSaved;
  final void Function(BuildTree tree)? onTreeBuilt;

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.onGeneratingChanged,
    required this.onLineSaved,
    this.onTreeBuilt,
  });

  @override
  State<RepertoireGenerationTab> createState() =>
      RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  // Legacy service kept for winRateOnly strategy
  final RepertoireGenerationService _legacyService =
      RepertoireGenerationService();
  final TreeBuildService _buildService = TreeBuildService();

  static const int _pgnFlushEveryLines = 10;

  // ── Controllers ────────────────────────────────────────────────────────

  final TextEditingController _cutoffCtrl =
      TextEditingController(text: '0.01');
  final TextEditingController _depthCtrl = TextEditingController(text: '30');
  final TextEditingController _engineDepthCtrl =
      TextEditingController(text: '20');
  final TextEditingController _evalGuardCtrl =
      TextEditingController(text: '50');
  late final TextEditingController _minEvalCtrl;
  late final TextEditingController _maxEvalCtrl;
  final TextEditingController _trickWeightCtrl =
      TextEditingController(text: '50');
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2200');

  // Advanced
  final TextEditingController _multipvRootCtrl =
      TextEditingController(text: '10');
  final TextEditingController _multipvFloorCtrl =
      TextEditingController(text: '2');
  final TextEditingController _taperDepthCtrl =
      TextEditingController(text: '8');
  final TextEditingController _oppMaxChildrenCtrl =
      TextEditingController(text: '6');
  final TextEditingController _oppMassRootCtrl =
      TextEditingController(text: '0.95');
  final TextEditingController _oppMassFloorCtrl =
      TextEditingController(text: '0.50');

  bool _useLichessDb = false;
  bool _relativeEval = false;

  _GenerationMode _mode = _GenerationMode.treeBuild;
  bool _showAdvanced = false;
  bool _isGenerating = false;
  bool _cancelRequested = false;
  String _status = 'Idle';
  int _nodes = 0;
  int _lines = 0;
  int _depth = 0;
  int _engineCalls = 0;
  int _engineCacheHits = 0;
  int _maiaCalls = 0;
  int _lichessQueries = 0;
  int _elapsedMs = 0;
  DateTime _lastProgressUpdate = DateTime(0);
  final StringBuffer _pendingPgnBuffer = StringBuffer();
  int _pendingPgnLines = 0;

  @override
  void initState() {
    super.initState();
    _minEvalCtrl = TextEditingController(
      text: widget.isWhiteRepertoire ? '0' : '-200',
    );
    _maxEvalCtrl = TextEditingController(
      text: widget.isWhiteRepertoire ? '200' : '100',
    );
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _depthCtrl.dispose();
    _engineDepthCtrl.dispose();
    _evalGuardCtrl.dispose();
    _minEvalCtrl.dispose();
    _maxEvalCtrl.dispose();
    _trickWeightCtrl.dispose();
    _maiaEloCtrl.dispose();
    _multipvRootCtrl.dispose();
    _multipvFloorCtrl.dispose();
    _taperDepthCtrl.dispose();
    _oppMaxChildrenCtrl.dispose();
    _oppMassRootCtrl.dispose();
    _oppMassFloorCtrl.dispose();
    super.dispose();
  }

  void cancelGeneration({String? reason}) {
    if (!_isGenerating) return;
    _cancelRequested = true;
    if (_mode == _GenerationMode.treeBuild) {
      _buildService.stopBuild();
    }
    if (mounted && reason != null && reason.isNotEmpty) {
      setState(() => _status = reason);
    }
  }

  // ── Tree build generation ─────────────────────────────────────────────

  Future<void> _startTreeBuild() async {
    if (_isGenerating) return;
    final filePath = widget.currentRepertoire?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      setState(() => _status = 'Select a repertoire first.');
      return;
    }

    final config = TreeBuildConfig(
      startFen: widget.fen,
      playAsWhite: widget.isWhiteRepertoire,
      minProbability: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: 0.01,
      ),
      maxDepth: int.tryParse(_depthCtrl.text.trim()) ?? 30,
      evalDepth: int.tryParse(_engineDepthCtrl.text.trim()) ?? 20,
      maxEvalLossCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 50,
      minEvalCp: int.tryParse(_minEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 0 : -200),
      maxEvalCp: int.tryParse(_maxEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 200 : 100),
      trickWeight: int.tryParse(_trickWeightCtrl.text.trim()) ?? 50,
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
      ourMultipvRoot: int.tryParse(_multipvRootCtrl.text.trim()) ?? 10,
      ourMultipvFloor: int.tryParse(_multipvFloorCtrl.text.trim()) ?? 2,
      taperDepth: int.tryParse(_taperDepthCtrl.text.trim()) ?? 8,
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 6,
      oppMassRoot: double.tryParse(_oppMassRootCtrl.text.trim()) ?? 0.95,
      oppMassFloor: double.tryParse(_oppMassFloorCtrl.text.trim()) ?? 0.50,
      useLichessDb: _useLichessDb,
      relativeEval: _relativeEval,
    );

    setState(() {
      _isGenerating = true;
      _cancelRequested = false;
      _status = 'Phase 1: Building tree...';
      _nodes = 0;
      _lines = 0;
      _depth = 0;
      _engineCalls = 0;
      _engineCacheHits = 0;
      _maiaCalls = 0;
      _lichessQueries = 0;
      _elapsedMs = 0;
    });
    _pendingPgnBuffer.clear();
    _pendingPgnLines = 0;
    widget.onGeneratingChanged(true);

    try {
      // Phase 1: Build tree
      final tree = await _buildService.build(
        config: config,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (!mounted) return;
          _nodes = p.totalNodes;
          _depth = p.currentDepth;
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

      // Phase 2c: Select repertoire moves
      if (mounted) {
        setState(() => _status = 'Phase 2: Selecting repertoire...');
      }
      final selector = RepertoireSelector(config: config, ecaCalc: ecaCalc);
      final selectedCount = selector.select(tree);

      // Phase 3: Extract lines
      if (mounted) setState(() => _status = 'Phase 3: Extracting lines...');
      final extractor = LineExtractor(config: config);
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
        final treePath = '${filePath.replaceAll('.pgn', '')}_tree.json';
        await File(treePath).writeAsString(treeJson);
      } catch (_) {
        // Tree JSON save is best-effort
      }

      if (mounted) {
        setState(() {
          _status = 'Complete: ${tree.totalNodes} nodes, '
              '$selectedCount repertoire moves, '
              '$_lines lines. '
              '(ease=$easeCount, eca=$ecaCount)';
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
      if (mounted) setState(() => _isGenerating = false);
      widget.onGeneratingChanged(false);
    }
  }

  // ── Legacy winRateOnly generation ─────────────────────────────────────

  Future<void> _startLegacyGeneration() async {
    if (_isGenerating) return;
    final filePath = widget.currentRepertoire?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      setState(() => _status = 'Select a repertoire first.');
      return;
    }

    final config = RepertoireGenerationConfig(
      startFen: widget.fen,
      isWhiteRepertoire: widget.isWhiteRepertoire,
      cumulativeProbabilityCutoff: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: 0.01,
      ),
      maxDepthPly: int.tryParse(_depthCtrl.text.trim()) ?? 30,
      opponentMassTarget: double.tryParse(_oppMassRootCtrl.text.trim()) ?? 0.80,
      engineDepth: int.tryParse(_engineDepthCtrl.text.trim()) ?? 20,
      maxEvalLossCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 50,
      minEvalCpForUs: int.tryParse(_minEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 0 : -200),
      maxEvalCpForUs: int.tryParse(_maxEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 200 : 100),
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
    );

    setState(() {
      _isGenerating = true;
      _cancelRequested = false;
      _status = 'Starting DB-only generation...';
      _nodes = 0;
      _lines = 0;
      _depth = 0;
      _engineCalls = 0;
      _engineCacheHits = 0;
      _elapsedMs = 0;
    });
    _pendingPgnBuffer.clear();
    _pendingPgnLines = 0;
    widget.onGeneratingChanged(true);

    try {
      await _legacyService.generate(
        config: config,
        strategy: GenerationStrategy.winRateOnly,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (!mounted) return;
          _nodes = p.nodesVisited;
          _lines = p.linesGenerated;
          _depth = p.currentDepth;
          _engineCalls = p.dbCalls;
          _engineCacheHits = p.dbCacheHits;
          _elapsedMs = p.elapsedMs;
          _status = p.message;

          final now = DateTime.now();
          if (now.difference(_lastProgressUpdate).inMilliseconds < 150) return;
          _lastProgressUpdate = now;
          setState(() {});
        },
        onLine: (line) async {
          final idx = _lines + 1;
          final title = 'Generated Line $idx';
          final fullMoves = [...widget.currentMoveSequence, ...line.movesSan];
          final pgn = _buildPgnEntry(
            moves: fullMoves,
            title: title,
            cumulativeProb: line.cumulativeProbability,
            finalEvalCp: line.finalEvalWhiteCp,
          );
          _queuePgnEntry(pgn);
          if (_pendingPgnLines >= _pgnFlushEveryLines) {
            await _flushPendingPgnWrites(filePath);
          }
          widget.onLineSaved(fullMoves, title, pgn);
          if (!mounted) return;
          setState(() => _status = 'Saved line $idx');
        },
      );

      await _flushPendingPgnWrites(filePath);

      if (!mounted) return;
      setState(() {
        _status = _cancelRequested
            ? 'Generation cancelled. Saved $_lines lines.'
            : 'Generation complete. Saved $_lines lines.';
      });
    } catch (e) {
      final fp = widget.currentRepertoire?['filePath'] as String?;
      if (fp != null && fp.isNotEmpty) {
        await _flushPendingPgnWrites(fp);
      }
      if (!mounted) return;
      setState(() => _status = 'Generation failed: $e');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
      widget.onGeneratingChanged(false);
    }
  }

  // ── Dispatch ──────────────────────────────────────────────────────────

  Future<void> _startGeneration() async {
    if (_mode == _GenerationMode.winRateOnly) {
      await _startLegacyGeneration();
    } else {
      await _startTreeBuild();
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
    final line = _movesToPgnMoveText(moves);

    final annotation = StringBuffer()
      ..write('{CumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%'
          ', Eval $finalEvalCp cp');
    if (pruneReason == PruneReason.evalTooHigh && pruneEvalCp != null) {
      annotation.write(
          ', Already winning (${pruneEvalCp >= 0 ? "+" : ""}${(pruneEvalCp / 100).toStringAsFixed(1)})');
    }
    annotation.write('}');

    return [
      '[Event "$title"]',
      '[Date "$date"]',
      '[White "$whiteName"]',
      '[Black "$blackName"]',
      '[Result "*"]',
      '[Annotator "AutoGenerate"]',
      '',
      '$annotation',
      '$line *',
    ].join('\n');
  }

  String _movesToPgnMoveText(List<String> moves) {
    if (moves.isEmpty) return '';
    final sb = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i.isEven) sb.write('${(i ~/ 2) + 1}. ');
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
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          if (_isGenerating)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          _statChip('Nodes', '$_nodes'),
          _statChip('Lines', '$_lines'),
          _statChip('d', '$_depth'),
          _statChip('Eng', '$_engineCalls'),
          if (_engineCacheHits > 0) _statChip('Cached', '$_engineCacheHits'),
          if (_maiaCalls > 0) _statChip('Maia', '$_maiaCalls'),
          if (_lichessQueries > 0) _statChip('Lichess', '$_lichessQueries'),
          Text(elapsed,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )),
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
    return Padding(
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
              _numField(_depthCtrl, 'Max Depth Ply'),
              _numField(_engineDepthCtrl, 'Engine Depth'),
              _numField(_evalGuardCtrl, 'Max Eval Loss (cp)'),
              _numField(_minEvalCtrl, 'Min Eval For Us (cp)'),
              _numField(_maxEvalCtrl, 'Max Eval For Us (cp)'),
              _numField(_trickWeightCtrl, 'Trick Weight (0-100)'),
              _numField(_maiaEloCtrl, 'Maia Elo'),
            ],
          ),
          const SizedBox(height: 8),

          // Advanced section
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                Icon(
                  _showAdvanced
                      ? Icons.expand_less
                      : Icons.expand_more,
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
                _numField(_multipvRootCtrl, 'MultiPV Root'),
                _numField(_multipvFloorCtrl, 'MultiPV Floor'),
                _numField(_taperDepthCtrl, 'Taper Depth'),
                _numField(_oppMaxChildrenCtrl, 'Opp Max Children'),
                _numField(_oppMassRootCtrl, 'Opp Mass Root'),
                _numField(_oppMassFloorCtrl, 'Opp Mass Floor'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _toggleSwitch('Lichess DB', _useLichessDb, (v) {
                  setState(() => _useLichessDb = v);
                }),
                const SizedBox(width: 16),
                _toggleSwitch('Relative Eval', _relativeEval, (v) {
                  setState(() => _relativeEval = v);
                }),
              ],
            ),
          ],
          const SizedBox(height: 8),

          // Mode selector
          DropdownButtonFormField<_GenerationMode>(
            value: _mode,
            decoration: const InputDecoration(
              labelText: 'Generation Mode',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(
                value: _GenerationMode.treeBuild,
                child: Text('Two-phase tree build (ECA)'),
              ),
              DropdownMenuItem(
                value: _GenerationMode.winRateOnly,
                child: Text('Win rate only (DB-only, no engine)'),
              ),
            ],
            onChanged: _isGenerating
                ? null
                : (v) {
                    if (v != null) setState(() => _mode = v);
                  },
          ),
          const SizedBox(height: 8),

          // Action buttons
          Row(
            children: [
              FilledButton.icon(
                onPressed: _isGenerating ? null : _startGeneration,
                icon: const Icon(Icons.play_arrow),
                label: Text(_mode == _GenerationMode.treeBuild
                    ? 'Build Repertoire Tree'
                    : 'Start DB-Only Generation'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _isGenerating ? () => cancelGeneration() : null,
                icon: const Icon(Icons.stop),
                label: const Text('Cancel'),
              ),
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
            _mode == _GenerationMode.winRateOnly
                ? 'DB-only: picks highest win-rate move per node. No engine analysis.'
                : 'Two-phase: builds full tree with MultiPV tapering + Maia,'
                    ' then computes ECA and selects repertoire lines.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _numField(TextEditingController controller, String label) {
    return SizedBox(
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
  }

  Widget _toggleSwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
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
  }

  double _parsePercentToFraction(
    String raw, {
    required double fallbackPercent,
  }) {
    final parsed = double.tryParse(raw.replaceAll('%', '').trim());
    final safePercent = (parsed ?? fallbackPercent).clamp(0.0, 100.0);
    return safePercent / 100.0;
  }
}

enum _GenerationMode {
  treeBuild,
  winRateOnly,
}
