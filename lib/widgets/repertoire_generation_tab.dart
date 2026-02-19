library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/repertoire_generation_service.dart';

class RepertoireGenerationTab extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final Map<String, dynamic>? currentRepertoire;
  final void Function(bool generating) onGeneratingChanged;
  final void Function(List<String> moves, String title, String pgn) onLineSaved;

  const RepertoireGenerationTab({
    super.key,
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.onGeneratingChanged,
    required this.onLineSaved,
  });

  @override
  State<RepertoireGenerationTab> createState() => RepertoireGenerationTabState();
}

class RepertoireGenerationTabState extends State<RepertoireGenerationTab> {
  final RepertoireGenerationService _service = RepertoireGenerationService();

  final TextEditingController _cutoffCtrl = TextEditingController(text: '0.001');
  final TextEditingController _depthCtrl = TextEditingController(text: '15');
  final TextEditingController _opponentMassCtrl = TextEditingController(text: '0.80');
  final TextEditingController _engineDepthCtrl = TextEditingController(text: '20');
  final TextEditingController _lineCapCtrl = TextEditingController(text: '64');
  final TextEditingController _evalGuardCtrl = TextEditingController(text: '50');
  final TextEditingController _minEvalCtrl = TextEditingController(text: '0');
  final TextEditingController _maxEvalCtrl = TextEditingController(text: '200');
  final TextEditingController _alphaCtrl = TextEditingController(text: '0.35');

  GenerationStrategy _strategy = GenerationStrategy.metaEval;
  bool _isGenerating = false;
  bool _cancelRequested = false;
  String _status = 'Idle';
  int _nodes = 0;
  int _lines = 0;
  int _depth = 0;

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _depthCtrl.dispose();
    _opponentMassCtrl.dispose();
    _engineDepthCtrl.dispose();
    _lineCapCtrl.dispose();
    _evalGuardCtrl.dispose();
    _minEvalCtrl.dispose();
    _maxEvalCtrl.dispose();
    _alphaCtrl.dispose();
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
      cumulativeProbabilityCutoff: double.tryParse(_cutoffCtrl.text.trim()) ?? 0.001,
      maxDepthPly: int.tryParse(_depthCtrl.text.trim()) ?? 15,
      opponentMassTarget: double.tryParse(_opponentMassCtrl.text.trim()) ?? 0.80,
      engineDepth: int.tryParse(_engineDepthCtrl.text.trim()) ?? 20,
      maxLines: int.tryParse(_lineCapCtrl.text.trim()) ?? 64,
      evalGuardCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 50,
      minEvalCpForUs: int.tryParse(_minEvalCtrl.text.trim()) ?? 0,
      maxEvalCpForUs: int.tryParse(_maxEvalCtrl.text.trim()) ?? 200,
      metaAlpha: double.tryParse(_alphaCtrl.text.trim()) ?? 0.35,
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
    });
    widget.onGeneratingChanged(true);

    try {
      await _service.generate(
        config: config,
        strategy: _strategy,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _nodes = p.nodesVisited;
            _lines = p.linesGenerated;
            _depth = p.currentDepth;
            _status = p.message;
          });
        },
        onLine: (line) async {
          // Use the service's counter (reported via onProgress) as
          // the authoritative line count. Don't double-increment.
          final idx = _lines + 1;
          final title = 'Generated Line $idx';
          final pgn = _buildPgnEntry(
            moves: line.movesSan,
            title: title,
            cumulativeProb: line.cumulativeProbability,
            finalEvalWhiteCp: line.finalEvalWhiteCp,
            metaEase: line.metaEase,
          );

          await File(filePath).writeAsString(
            '\n$pgn\n',
            mode: FileMode.append,
            flush: true,
          );

          widget.onLineSaved(line.movesSan, title, pgn);
          if (!mounted) return;
          setState(() {
            _status = 'Saved line $idx';
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _status = _cancelRequested
            ? 'Generation cancelled. Saved $_lines lines.'
            : 'Generation complete. Saved $_lines lines.';
      });
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Auto Repertoire Generation',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_cutoffCtrl, 'Cum Prob Cutoff'),
              _numField(_depthCtrl, 'Max Depth Ply'),
              _numField(_opponentMassCtrl, 'Opp Mass'),
              _numField(_engineDepthCtrl, 'Engine Depth'),
              _numField(_lineCapCtrl, 'Max Lines'),
              _numField(_evalGuardCtrl, 'Eval Guard (cp)'),
              _numField(_minEvalCtrl, 'Min Eval For Us (cp)'),
              _numField(_maxEvalCtrl, 'Max Eval For Us (cp)'),
              _numField(_alphaCtrl, 'Meta Alpha'),
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
              const SizedBox(width: 16),
              Text('Nodes: $_nodes  Lines: $_lines  Depth: $_depth'),
            ],
          ),
          const SizedBox(height: 8),
          Text(_status, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          const Text(
            'Our candidates: Top 3 engine moves + likely DB/MAIA moves, capped at 8.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
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
}
