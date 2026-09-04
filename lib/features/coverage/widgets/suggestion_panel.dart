/// Coverage suggestion panel — shows ranked lines to fill gaps.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/chess_utils.dart';
import '../../../widgets/clickable_move_line.dart';
import '../../../widgets/common/stat_display.dart';

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
  List<SuggestedLine> _suggestions = [];
  bool _isLoading = false;

  static const _defaultWeights = SuggestionWeights();
  late final _impactCtrl = _weightCtrl(_defaultWeights.impactExp);
  late final _evalCtrl = _weightCtrl(_defaultWeights.evalExp);
  late final _easeCtrl = _weightCtrl(_defaultWeights.easeExp);
  late final _trapCtrl = _weightCtrl(_defaultWeights.trapExp);
  late final _coherenceCtrl = _weightCtrl(_defaultWeights.coherenceExp);

  static TextEditingController _weightCtrl(double v) =>
      TextEditingController(text: _fmt(v));

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    _targetCoverage = (widget.currentCoverage + 10).clamp(0, 100);
  }

  @override
  void dispose() {
    for (final c in [
      _impactCtrl,
      _evalCtrl,
      _easeCtrl,
      _trapCtrl,
      _coherenceCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The weights as typed; a blank or unparseable field keeps its default.
  SuggestionWeights get _weights {
    double read(TextEditingController c, double fallback) =>
        (double.tryParse(c.text.trim()) ?? fallback).clamp(0.0, 5.0);
    return SuggestionWeights(
      impactExp: read(_impactCtrl, _defaultWeights.impactExp),
      evalExp: read(_evalCtrl, _defaultWeights.evalExp),
      easeExp: read(_easeCtrl, _defaultWeights.easeExp),
      trapExp: read(_trapCtrl, _defaultWeights.trapExp),
      coherenceExp: read(_coherenceCtrl, _defaultWeights.coherenceExp),
    );
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
        _buildWeights(theme),
        const Divider(height: 1),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_suggestions.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_fix_high,
                    size: 48,
                    color: AppColors.onSurfaceSoft,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Set a target and tap Generate',
                    style: theme.textTheme.bodyMedium,
                  ),
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
                  setState(() => _suggestions.removeAt(i));
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
              Text('Coverage: ', style: theme.textTheme.bodyMedium),
              Text(
                '${widget.currentCoverage.toStringAsFixed(1)}%',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text('Target: ', style: theme.textTheme.bodyMedium),
              Text(
                '${_targetCoverage.round()}%',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
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

  /// One field per scoring factor.  Each is an exponent: 0 ignores the
  /// factor, 1 weighs it fully, and they multiply, so the ratios matter more
  /// than the absolute numbers.
  Widget _buildWeights(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _weightField(
            _impactCtrl,
            'Coverage',
            'How much of your games the line accounts for.',
          ),
          _weightField(
            _evalCtrl,
            'Eval',
            'Engine eval at the end of the line, for you.',
          ),
          _weightField(
            _easeCtrl,
            'Ease',
            'How natural the line\'s moves are to find over the board.',
          ),
          _weightField(
            _trapCtrl,
            'Traps',
            'Positions in the line where opponents tend to go wrong.',
          ),
          _weightField(
            _coherenceCtrl,
            'Coherence',
            'How well the line fits the structures the repertoire already '
                'plays.',
          ),
        ],
      ),
    );
  }

  Widget _weightField(
    TextEditingController controller,
    String label,
    String tooltip,
  ) {
    return Tooltip(
      message:
          '$tooltip 0 ignores it; weights multiply, so only their '
          'ratios matter.',
      child: SizedBox(
        width: 88,
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final totalGain = _suggestions.fold(0.0, (sum, s) => sum + s.coverageGain);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Text(
            '${_suggestions.length} suggestions (+${totalGain.toStringAsFixed(1)}%)',
            style: theme.textTheme.bodySmall,
          ),
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
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '#${index + 1}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '+${suggestion.coverageGain.toStringAsFixed(1)}% coverage',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.coverageCovered,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceInset,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      suggestion.source,
                      style: const TextStyle(fontSize: 12),
                    ),
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
                    startFen,
                    suggestion.fullMoves,
                    idx,
                  );
                  boardPreview.setPreview(fen);
                },
                onHoverExit: () => boardPreview.clearPreview(),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (suggestion.leafEvalCp != null) ...[
                    InlineStat(
                      separator: ': ',
                      label: 'Eval',
                      value: _formatEval(suggestion.leafEvalCp!),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (suggestion.linePlayability != null) ...[
                    InlineStat(
                      separator: ': ',
                      label: 'Ease',
                      value: '${(suggestion.linePlayability! * 100).round()}%',
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (suggestion.trapCount > 0)
                    InlineStat(
                      separator: ': ',
                      label: 'Traps',
                      value: '${suggestion.trapCount}',
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: onAccept,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Accept (+${suggestion.coverageGain.toStringAsFixed(1)}%)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatEval(int cp) => formatPackedEval(cp, decimals: 2);
}
