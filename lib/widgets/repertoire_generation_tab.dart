library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/repertoire_generation_service.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final Map<String, dynamic>? currentRepertoire;
  final List<String> currentMoveSequence;
  final void Function(bool generating) onGeneratingChanged;
  final void Function(List<String> moves, String title, String pgn) onLineSaved;

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.onGeneratingChanged,
    required this.onLineSaved,
  });

  @override
  State<RepertoireGenerationTab> createState() =>
      RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  final RepertoireGenerationService _service = RepertoireGenerationService();
  static const int _pgnFlushEveryLines = 10;
  static const double _defaultCumProbCutoffPercent = 0.1;

  final TextEditingController _cutoffCtrl =
      TextEditingController(text: '0.1');
  final TextEditingController _depthCtrl = TextEditingController(text: '15');
  final TextEditingController _opponentMassCtrl =
      TextEditingController(text: '0.80');
  final TextEditingController _engineDepthCtrl =
      TextEditingController(text: '20');
  final TextEditingController _evalGuardCtrl =
      TextEditingController(text: '50');
  late final TextEditingController _minEvalCtrl;
  late final TextEditingController _maxEvalCtrl;
  final TextEditingController _alphaCtrl = TextEditingController(text: '0.35');
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2100');
  // Max Load removed — workers field on EngineSettings is the control now.

  GenerationStrategy _strategy = GenerationStrategy.metaEval;
  bool _isGenerating = false;
  bool _cancelRequested = false;
  String _status = 'Idle';
  int _nodes = 0;
  int _lines = 0;
  int _depth = 0;
  int _dbCalls = 0;
  int _dbCacheHits = 0;
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
    // Max Load removed — workers are configured in EngineSettings.
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _depthCtrl.dispose();
    _opponentMassCtrl.dispose();
    _engineDepthCtrl.dispose();
    _evalGuardCtrl.dispose();
    _minEvalCtrl.dispose();
    _maxEvalCtrl.dispose();
    _alphaCtrl.dispose();
    _maiaEloCtrl.dispose();
    // Max Load controller removed.
    super.dispose();
  }

  void cancelGeneration({String? reason}) {
    if (!_isGenerating) return;
    _cancelRequested = true;
    if (mounted && reason != null && reason.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason)),
      );
    }
  }

  Future<void> _startGeneration() async {
    if (_isGenerating) return;
    final filePath = widget.currentRepertoire?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a repertoire before generating.')),
      );
      return;
    }

    final config = RepertoireGenerationConfig(
      startFen: widget.fen,
      isWhiteRepertoire: widget.isWhiteRepertoire,
      cumulativeProbabilityCutoff: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: _defaultCumProbCutoffPercent,
      ),
      maxDepthPly: int.tryParse(_depthCtrl.text.trim()) ?? 15,
      opponentMassTarget:
          double.tryParse(_opponentMassCtrl.text.trim()) ?? 0.80,
      engineDepth: int.tryParse(_engineDepthCtrl.text.trim()) ?? 20,
      maxEvalLossCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 50,
      minEvalCpForUs: int.tryParse(_minEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 0 : -200),
      maxEvalCpForUs: int.tryParse(_maxEvalCtrl.text.trim()) ??
          (widget.isWhiteRepertoire ? 200 : 100),
      metaAlpha: double.tryParse(_alphaCtrl.text.trim()) ?? 0.35,
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2100,
      engineTopK: 3,
      maxCandidates: 8,
    );

    setState(() {
      _isGenerating = true;
      _cancelRequested = false;
      _status = 'Starting generation...';
      _nodes = 0;
      _lines = 0;
      _depth = 0;
      _dbCalls = 0;
      _dbCacheHits = 0;
      _elapsedMs = 0;
    });
    _pendingPgnBuffer.clear();
    _pendingPgnLines = 0;
    widget.onGeneratingChanged(true);

    try {
      await _service.generate(
        config: config,
        strategy: _strategy,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (!mounted) return;
          _nodes = p.nodesVisited;
          _lines = p.linesGenerated;
          _depth = p.currentDepth;
          _dbCalls = p.dbCalls;
          _dbCacheHits = p.dbCacheHits;
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
            finalEvalWhiteCp: line.finalEvalWhiteCp,
            metaEase: line.metaEase,
          );

          _queuePgnEntry(pgn);
          if (_pendingPgnLines >= _pgnFlushEveryLines) {
            await _flushPendingPgnWrites(filePath);
          }

          widget.onLineSaved(fullMoves, title, pgn);
          if (!mounted) return;
          setState(() {
            _status = 'Saved line $idx';
          });
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
      setState(() {
        _status = 'Generation failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
      widget.onGeneratingChanged(false);
    }
  }

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
    required int finalEvalWhiteCp,
    required double metaEase,
  }) {
    final date = DateTime.now().toIso8601String().split('T').first;
    final whiteName = widget.isWhiteRepertoire ? 'Repertoire' : 'Opponent';
    final blackName = widget.isWhiteRepertoire ? 'Opponent' : 'Repertoire';
    final line = _movesToPgnMoveText(moves);

    return [
      '[Event "$title"]',
      '[Date "$date"]',
      '[White "$whiteName"]',
      '[Black "$blackName"]',
      '[Result "*"]',
      '[Annotator "AutoGenerate"]',
      '',
      '{CumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%, EvalW $finalEvalWhiteCp cp, MetaEase ${metaEase.toStringAsFixed(3)}}',
      '$line *',
    ].join('\n');
  }

  String _movesToPgnMoveText(List<String> moves) {
    if (moves.isEmpty) return '';
    final sb = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i.isEven) {
        sb.write('${(i ~/ 2) + 1}. ');
      }
      sb.write(moves[i]);
      sb.write(' ');
    }
    return sb.toString().trim();
  }

  Widget _buildProgressDisplay() {
    final secs = _elapsedMs / 1000.0;
    final rate = secs > 0.5 ? (_dbCalls / secs).toStringAsFixed(1) : '—';
    final elapsed = secs >= 60
        ? '${(secs / 60).floor()}m ${(secs % 60).toStringAsFixed(0)}s'
        : '${secs.toStringAsFixed(1)}s';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (_isGenerating)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Text(
            'API: $_dbCalls',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(width: 12),
          Text('Cached: $_dbCacheHits', style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          Text('Nodes: $_nodes', style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          Text('Lines: $_lines', style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          Text('d=$_depth', style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(
            '$rate req/s  ·  $elapsed',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_cutoffCtrl, 'Cum Prob Cutoff (%)'),
              _numField(_depthCtrl, 'Max Depth Ply'),
              _numField(_opponentMassCtrl, 'Opp Mass'),
              _numField(_engineDepthCtrl, 'Engine Depth'),
              _numField(_evalGuardCtrl, 'Max Eval Loss (cp)'),
              _numField(_minEvalCtrl, 'Min Eval For Us (cp)'),
              _numField(_maxEvalCtrl, 'Max Eval For Us (cp)'),
              _numField(_alphaCtrl, 'Meta Alpha'),
              _numField(_maiaEloCtrl, 'Maia Elo'),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<GenerationStrategy>(
            value: _strategy,
            decoration: const InputDecoration(
              labelText: 'Selection Algorithm',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(
                value: GenerationStrategy.engineOnly,
                child: Text('Engine only (greedy eval)'),
              ),
              DropdownMenuItem(
                value: GenerationStrategy.winRateOnly,
                child: Text('Win rate only (greedy DB)'),
              ),
              DropdownMenuItem(
                value: GenerationStrategy.metaEval,
                child: Text('MetaEval (propagated opponentEase)'),
              ),
            ],
            onChanged: _isGenerating
                ? null
                : (v) {
                    if (v != null) setState(() => _strategy = v);
                  },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _isGenerating ? null : _startGeneration,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start DFS Generation'),
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
            _strategy == GenerationStrategy.winRateOnly
                ? 'DB-only: picks highest win-rate move per node. No engine analysis.'
                : 'Our candidates: Top 3 engine moves + likely DB/MAIA moves, capped at 8.',
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

  double _parsePercentToFraction(
    String raw, {
    required double fallbackPercent,
  }) {
    final parsed = double.tryParse(raw.replaceAll('%', '').trim());
    final safePercent = (parsed ?? fallbackPercent).clamp(0.0, 100.0);
    return safePercent / 100.0;
  }
}
