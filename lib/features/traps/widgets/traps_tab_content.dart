/// Traps tab body: browser when traps exist, discovery empty-state otherwise.
library;

import 'package:flutter/material.dart';

import '../../../core/board_preview_controller.dart';
import '../models/trap_line_info.dart';
import '../services/trap_index_service.dart';
import 'traps_browser.dart';

class TrapsTabContent extends StatelessWidget {
  final List<TrapLineInfo> traps;
  final TrapIndexService? trapIndex;
  final List<String> currentMoveSequence;
  final List<List<String>> repertoireLineMoves;
  final BoardPreviewController boardPreview;

  /// Whether a repertoire file is loaded (drives the empty-state copy).
  final bool hasRepertoire;

  final void Function(TrapLineInfo trap) onTrapSelected;
  final VoidCallback onStartTour;
  final VoidCallback onDiscoverTraps;
  final VoidCallback onOpenGeneration;

  const TrapsTabContent({
    super.key,
    required this.traps,
    required this.trapIndex,
    required this.currentMoveSequence,
    required this.repertoireLineMoves,
    required this.boardPreview,
    required this.hasRepertoire,
    required this.onTrapSelected,
    required this.onStartTour,
    required this.onDiscoverTraps,
    required this.onOpenGeneration,
  });

  @override
  Widget build(BuildContext context) {
    if (traps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 48, color: Colors.grey[700]),
              const SizedBox(height: 16),
              Text(
                'No traps detected yet',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasRepertoire
                    ? 'Discover traps in your existing repertoire, or '
                        'generate a new repertoire to find them.'
                    : 'Generate a repertoire to discover positions where '
                        'opponents are likely to make mistakes.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
              const SizedBox(height: 20),
              if (hasRepertoire) ...[
                FilledButton.icon(
                  onPressed: onDiscoverTraps,
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('Discover Traps'),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: onOpenGeneration,
                  icon: const Icon(Icons.auto_awesome, size: 14),
                  label: const Text('Generate Full Repertoire'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[400],
                  ),
                ),
              ] else
                FilledButton.icon(
                  onPressed: onOpenGeneration,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Generate Repertoire'),
                ),
            ],
          ),
        ),
      );
    }
    return TrapsBrowser(
      traps: traps,
      currentMoveSequence: currentMoveSequence,
      boardPreview: boardPreview,
      metrics: trapIndex?.metrics,
      repertoireLineMoves: repertoireLineMoves,
      onTrapSelected: onTrapSelected,
      onStartTour: onStartTour,
    );
  }
}
