/// Engine-resources panel for the generation config form: shows logical-core
/// info, the Stockfish UCI-threads field, and live thread/hash stat chips.
/// Extracted from `GenerationConfigForm`.
library;

import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/engine/stockfish_pool.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_text_styles.dart';
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
    final workers = StockfishPool.laneCountFor(clamped);
    final threadsPerWorker = StockfishPool.threadsPerLane(clamped, workers);
    final activeThreads = workers * threadsPerWorker;
    final hashMb = workers * EngineSettings.instance.hashMb;
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
            'This computer has $cores CPU core${cores == 1 ? '' : 's'}. The '
            'build splits the number below across separate Stockfish '
            'processes so several positions are searched at once.',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: 'CPU cores this build may use, 1 to $cores.',
                child: SizedBox(
                  width: 210,
                  child: TextField(
                    controller: threadsController,
                    enabled: enabled && !isGenerating,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: false,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'CPU cores for this build',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              _ConfigStatChip(
                label:
                    '$workers process${workers == 1 ? '' : 'es'} × '
                    '$threadsPerWorker thread${threadsPerWorker == 1 ? '' : 's'}',
              ),
              _ConfigStatChip(
                label:
                    '$activeThreads of $clamped cores in use · '
                    '$hashMb MB RAM for search tables',
              ),
            ],
          ),
          if (!enabled) ...[
            const SizedBox(height: 6),
            const Text(
              'No engine in this build source.',
              style: AppTextStyles.caption,
            ),
          ] else if (isDbExplorer) ...[
            const SizedBox(height: 6),
            const Text(
              'Engine runs during eval enrichment after the PGN tree is built.',
              style: AppTextStyles.caption,
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
    return Text(label, style: AppTextStyles.caption);
  }
}
