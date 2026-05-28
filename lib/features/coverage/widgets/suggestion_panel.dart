/// Coverage suggestion panel — shows ranked lines to fill gaps.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import '../../../utils/chess_utils.dart';
import '../../../widgets/clickable_move_line.dart';

class SuggestionPanel extends StatefulWidget {
  final CoverageSuggestionService service;
  final bool playAsWhite;
  final BoardPreviewController boardPreview;
  final double currentCoverage;
  final void Function(SuggestedLine suggestion)? onAccept;
  final VoidCallback? onAcceptAll;

  const SuggestionPanel({
    super.key,
    required this.service,
    required this.playAsWhite,
    required this.boardPreview,
    required this.currentCoverage,
    this.onAccept,
    this.onAcceptAll,
  });

  @override
  State<SuggestionPanel> createState() => _SuggestionPanelState();
}

class _SuggestionPanelState extends State<SuggestionPanel> {
  double _targetCoverage = 75.0;
  SuggestionWeights _weights = SuggestionWeights.balanced;
  List<SuggestedLine> _suggestions = [];
  bool _isLoading = false;
  String _activePreset = 'balanced';

  @override
  void initState() {
    super.initState();
    _targetCoverage = (widget.currentCoverage + 10).clamp(0, 100);
  }

  void _generate() {
    setState(() => _isLoading = true);
    _suggestions = widget.service.generateSuggestions(
      targetCoverage: _targetCoverage,
      playAsWhite: widget.playAsWhite,
      weights: _weights,
    );
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(theme),
        _buildPresets(theme),
        const Divider(height: 1),
        if (_isLoading)
          const Expanded(
              child: Center(child: CircularProgressIndicator()))
        else if (_suggestions.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_fix_high,
                      size: 48, color: Colors.grey.shade400),
                  const SizedBox(height: 8),
                  Text('Set a target and tap Generate',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _suggestions.length,
              itemBuilder: (ctx, i) => _SuggestionRow(
                suggestion: _suggestions[i],
                index: i,
                onAccept: () {
                  widget.onAccept?.call(_suggestions[i]);
                  setState(
                      () => _suggestions.removeAt(i));
                },
                boardPreview: widget.boardPreview,
              ),
            ),
          ),
        if (_suggestions.isNotEmpty) _buildFooter(theme),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Coverage: ',
                  style: theme.textTheme.bodyMedium),
              Text(
                  '${widget.currentCoverage.toStringAsFixed(1)}%',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('Target: ',
                  style: theme.textTheme.bodyMedium),
              Text('${_targetCoverage.round()}%',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          Slider(
            value: _targetCoverage,
            min: widget.currentCoverage.clamp(0, 99),
            max: 100,
            divisions: 20,
            label: '${_targetCoverage.round()}%',
            onChanged: (v) => setState(() => _targetCoverage = v),
          ),
          Center(
            child: FilledButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Generate Suggestions'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresets(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        spacing: 8,
        children: [
          _presetChip('Max Coverage', 'max', SuggestionWeights.maxCoverage),
          _presetChip('Balanced', 'balanced', SuggestionWeights.balanced),
          _presetChip('Playable', 'playable', SuggestionWeights.playable),
          _presetChip('Trappy', 'trappy', SuggestionWeights.trappy),
        ],
      ),
    );
  }

  Widget _presetChip(String label, String id, SuggestionWeights w) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: _activePreset == id,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _activePreset = id;
            _weights = w;
          });
        }
      },
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final totalGain =
        _suggestions.fold(0.0, (sum, s) => sum + s.coverageGain);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Text(
              '${_suggestions.length} suggestions (+${totalGain.toStringAsFixed(1)}%)',
              style: theme.textTheme.bodySmall),
          const Spacer(),
          FilledButton(
            onPressed: widget.onAcceptAll,
            child: const Text('Accept All'),
          ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  final SuggestedLine suggestion;
  final int index;
  final VoidCallback onAccept;
  final BoardPreviewController boardPreview;

  const _SuggestionRow({
    required this.suggestion,
    required this.index,
    required this.onAccept,
    required this.boardPreview,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) {
        if (suggestion.gap.fen.isNotEmpty) {
          boardPreview.setPreview(suggestion.gap.fen);
        }
      },
      onExit: (_) => boardPreview.clearPreview(),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('#${index + 1}',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      '+${suggestion.coverageGain.toStringAsFixed(1)}% coverage',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.green)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(suggestion.source,
                        style: const TextStyle(fontSize: 10)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClickableMoveLineWidget(
                sanMoves: suggestion.fullMoves,
                startPly: 0,
                maxMoves: 12,
                onMoveHovered: (idx, _) {
                  const startFen =
                      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
                  final fen = fenAfterMoves(
                      startFen, suggestion.fullMoves, idx);
                  boardPreview.setPreview(fen);
                },
                onHoverExit: () => boardPreview.clearPreview(),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (suggestion.leafEvalCp != null) ...[
                    _MetricChip(
                        label: 'Eval',
                        value: _formatEval(suggestion.leafEvalCp!)),
                    const SizedBox(width: 6),
                  ],
                  if (suggestion.linePlayability != null) ...[
                    _MetricChip(
                        label: 'Ease',
                        value:
                            '${(suggestion.linePlayability! * 100).round()}%'),
                    const SizedBox(width: 6),
                  ],
                  if (suggestion.trapCount > 0)
                    _MetricChip(
                        label: 'Traps',
                        value: '${suggestion.trapCount}'),
                  const Spacer(),
                  FilledButton(
                    onPressed: onAccept,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                        'Accept (+${suggestion.coverageGain.toStringAsFixed(1)}%)',
                        style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatEval(int cp) {
    final pawns = cp / 100.0;
    return '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(2)}';
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('$label: $value',
          style: const TextStyle(fontSize: 10)),
    );
  }
}
