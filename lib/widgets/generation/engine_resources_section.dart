/// Engine-resources panel for the generation config form: shows logical-core
/// info, the Stockfish UCI-threads field, and live thread/hash stat chips.
/// Extracted from `GenerationConfigForm`
/// (MAINTAINABILITY_PLAN WS-E / runbook A6).
library;

import 'package:flutter/material.dart';

import '../../services/engine/stockfish_pool.dart';
import '../../services/generation/generation_config.dart';
import '../../utils/system_info.dart';

class EngineResourcesSection extends StatelessWidget {
  const EngineResourcesSection({
    super.key,
    required this.threadsController,
    required this.isGenerating,
    required this.isDbExplorer,
  });

  /// Controller for the Stockfish UCI-threads field (owned by the form).
  final TextEditingController threadsController;

  /// Disables editing while a build is running.
  final bool isGenerating;

  /// When true, appends the db-explorer eval-enrichment note.
  final bool isDbExplorer;

  @override
  Widget build(BuildContext context) {
    final cores = getLogicalCores();
    final threads =
        int.tryParse(threadsController.text.trim()) ?? defaultEngineThreads();
    final clamped = threads.clamp(1, cores);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'Engine resources',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Your system has $cores logical core${cores == 1 ? '' : 's'}. '
            'Tree build uses 1 Stockfish worker with UCI Threads set below.',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message:
                    'Stockfish UCI threads during tree build (1–$cores). '
                    'MultiPV searches benefit strongly from multiple threads.',
                child: SizedBox(
                  width: 170,
                  child: TextField(
                    controller: threadsController,
                    enabled: !isGenerating,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: false),
                    decoration: const InputDecoration(
                      labelText: 'Engine Threads',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              _ConfigStatChip(
                label: '$clamped thread${clamped == 1 ? '' : 's'} active',
                color: scheme.primary,
              ),
              _ConfigStatChip(
                label: '$kPoolHashPerWorkerMb MB hash',
                color: scheme.secondary,
              ),
            ],
          ),
          if (isDbExplorer) ...[
            const SizedBox(height: 6),
            Text(
              'Engine runs during eval enrichment after the PGN tree is built.',
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfigStatChip extends StatelessWidget {
  const _ConfigStatChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(32),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(64)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color.withAlpha(220)),
      ),
    );
  }
}
