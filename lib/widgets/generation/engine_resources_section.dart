/// Engine-resources panel for the generation config form: shows logical-core
/// info, the Stockfish UCI-threads field, and live thread/hash stat chips.
/// Extracted from `GenerationConfigForm`.
library;

import 'package:flutter/material.dart';

import '../../services/engine/stockfish_pool.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import '../../utils/system_info.dart';

class EngineResourcesSection extends StatelessWidget {
  const EngineResourcesSection({
    super.key,
    required this.threadsController,
    required this.isGenerating,
    required this.isDbExplorer,
    this.enabled = true,
  });

  /// Controller for the Stockfish UCI-threads field (owned by the form).
  final TextEditingController threadsController;

  /// Disables editing while a build is running.
  final bool isGenerating;

  /// When true, appends the db-explorer eval-enrichment note.
  final bool isDbExplorer;

  /// When false, the build source uses no engine at all: the threads field
  /// is disabled in place and a note says why.
  final bool enabled;

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
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
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
                  width: 210,
                  child: TextField(
                    controller: threadsController,
                    enabled: enabled && !isGenerating,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: false,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Engine threads',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              _ConfigStatChip(
                label: '$clamped thread${clamped == 1 ? '' : 's'} active',
              ),
              const _ConfigStatChip(label: '$kPoolHashPerWorkerMb MB hash'),
            ],
          ),
          if (!enabled) ...[
            const SizedBox(height: 6),
            const Text(
              'No engine in this build source.',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
          ] else if (isDbExplorer) ...[
            const SizedBox(height: 6),
            const Text(
              'Engine runs during eval enrichment after the PGN tree is built.',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfigStatChip extends StatelessWidget {
  const _ConfigStatChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
    );
  }
}
