/// Coverage Calculator Widget
/// Config dialog + inline runner for repertoire coverage analysis
library;

import 'package:flutter/material.dart';
import 'package:chess_auto_prep/features/coverage/models/coverage_config.dart';
import '../../../services/maia/maia_factory.dart';

export 'package:chess_auto_prep/features/coverage/models/coverage_config.dart'
    show CoverageConfig;

/// Shows the coverage config dialog and returns the config, or null if cancelled.
Future<CoverageConfig?> showCoverageConfigDialog(BuildContext context) {
  return showDialog<CoverageConfig>(
    context: context,
    builder: (context) => const _CoverageConfigDialog(),
  );
}

class _CoverageConfigDialog extends StatefulWidget {
  const _CoverageConfigDialog();

  @override
  State<_CoverageConfigDialog> createState() => _CoverageConfigDialogState();
}

class _CoverageConfigDialogState extends State<_CoverageConfigDialog> {
  double _targetPercent = 1.0;
  final _customTargetController = TextEditingController(text: '1');
  bool _useMaia = MaiaFactory.isAvailable;
  int _maiaElo = 2200;
  final _maiaEloController = TextEditingController(text: '2200');

  @override
  void dispose() {
    _customTargetController.dispose();
    _maiaEloController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.analytics_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          const Expanded(child: Text('Coverage Analysis')),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Measured against your master-games database: the share of '
                'games reaching this repertoire that it still answers.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),
              _buildThresholdSection(theme),
              const Divider(height: 24),
              _buildMaiaSection(theme),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Analyze Coverage'),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(
      CoverageConfig(
        targetPercent: _targetPercent,
        useMaia: _useMaia,
        maiaElo: _maiaElo,
      ),
    );
  }

  // ── Threshold ──────────────────────────────────────────────────────────

  Widget _buildThresholdSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Target Threshold',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Stop expanding once a position has less than this chance of being reached from the root.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 56,
          child: TextField(
            controller: _customTargetController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              suffixText: '%',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (value) {
              final parsed = double.tryParse(value);
              if (parsed != null && parsed > 0 && parsed <= 100) {
                setState(() => _targetPercent = parsed);
              }
            },
          ),
        ),
      ],
    );
  }

  // ── Maia fallback ──────────────────────────────────────────────────────

  Widget _buildMaiaSection(ThemeData theme) {
    final maiaAvailable = MaiaFactory.isAvailable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Maia Fallback',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Switch(
              value: _useMaia && maiaAvailable,
              onChanged: maiaAvailable
                  ? (value) => setState(() => _useMaia = value)
                  : null,
            ),
          ],
        ),
        Text(
          maiaAvailable
              ? 'Use Maia neural network when Lichess DB has no data for a position.'
              : 'Maia is not available on this platform.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        if (_useMaia && maiaAvailable) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Elo: ', style: theme.textTheme.bodyMedium),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _maiaEloController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (value) {
                    final parsed = int.tryParse(value);
                    if (parsed != null && parsed >= 400 && parsed <= 3000) {
                      _maiaElo = parsed;
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
