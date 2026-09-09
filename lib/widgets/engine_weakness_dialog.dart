/// Config dialog for engine weakness analysis.
///
/// Returns an [EngineWeaknessConfig] when the user taps "Start", or null
/// if cancelled.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/engine_settings.dart';
import '../models/bulk_analysis_settings.dart';
import '../theme/app_colors.dart';
import 'info_hint.dart';

/// Settings returned by the config dialog.
class EngineWeaknessConfig {
  final int depth;
  final int minGames;
  final int whiteCp;
  final int blackCp;
  final int workers;

  const EngineWeaknessConfig({
    required this.depth,
    required this.minGames,
    required this.whiteCp,
    required this.blackCp,
    required this.workers,
  });
}

class EngineWeaknessConfigDialog extends StatefulWidget {
  /// True when the player already has engine evals, i.e. this run replaces
  /// them. Only changes the wording of the header.
  final bool isReanalysis;

  const EngineWeaknessConfigDialog({super.key, this.isReanalysis = false});

  @override
  State<EngineWeaknessConfigDialog> createState() =>
      _EngineWeaknessConfigDialogState();
}

class _EngineWeaknessConfigDialogState
    extends State<EngineWeaknessConfigDialog> {
  late final TextEditingController _minGamesCtrl;
  late final TextEditingController _whiteCpCtrl;
  late final TextEditingController _blackCpCtrl;

  @override
  void initState() {
    super.initState();
    _minGamesCtrl = TextEditingController(text: '3');
    _whiteCpCtrl = TextEditingController(text: '-50');
    _blackCpCtrl = TextEditingController(text: '100');
  }

  @override
  void dispose() {
    _minGamesCtrl.dispose();
    _whiteCpCtrl.dispose();
    _blackCpCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      EngineWeaknessConfig(
        depth: BulkAnalysisSettings.instance.depth,
        minGames: int.tryParse(_minGamesCtrl.text) ?? 3,
        whiteCp: int.tryParse(_whiteCpCtrl.text) ?? -50,
        blackCp: int.tryParse(_blackCpCtrl.text) ?? 100,
        workers: EngineSettings.instance.cores,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              const Divider(height: 24),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _field(
                    'Min games',
                    _minGamesCtrl,
                    80,
                    hint:
                        'Skip positions you have reached fewer times than this.\n'
                        'Raising it keeps the run on lines you actually play '
                        'instead of\none-off transpositions.',
                  ),
                  _field(
                    'CP score (white)',
                    _whiteCpCtrl,
                    120,
                    hint:
                        'Flags a position as bad for White when the evaluation is\n'
                        'at or below this, in centipawns (100 = one pawn).\n'
                        'Negative means White already stands worse, so -50 marks\n'
                        '"half a pawn down or worse". Only affects which positions\n'
                        'are highlighted — every position is still evaluated.',
                  ),
                  _field(
                    'CP score (black)',
                    _blackCpCtrl,
                    120,
                    hint:
                        'Flags a position as bad for Black when the evaluation is\n'
                        'at or above this, in centipawns (100 = one pawn).\n'
                        'Evaluations are always from White\'s side, so a positive\n'
                        'number means Black stands worse: 100 marks "a pawn down\n'
                        'or worse". Only affects highlighting, not what is evaluated.',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    // On a re-run the title says what the button said — "Re-analyze" — and the
    // explanation drops to the subtitle, rather than repeating the first-run
    // title back at someone who has already done this once.
    final title = widget.isReanalysis ? 'Re-analyze' : 'Analyze with Engine';
    final subtitle = widget.isReanalysis
        ? 'Analyze with Engine · re-evaluate your most-played positions '
              'with Stockfish'
        : 'Evaluate your most-played positions with Stockfish';

    return Row(
      children: [
        const Icon(Icons.memory, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.onSurfaceSoft,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl,
    double width, {
    bool enabled = true,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? null : AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(width: 4),
            InfoHint(hint, size: 14),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: width,
          child: TextField(
            controller: ctrl,
            enabled: enabled,
            style: const TextStyle(fontSize: 13),
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}
