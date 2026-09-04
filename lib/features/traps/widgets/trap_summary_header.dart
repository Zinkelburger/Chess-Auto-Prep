/// Repertoire-level trap summary shown at the top of the Traps tab.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';

import '../../../theme/app_colors.dart';
import '../../../widgets/common/stat_display.dart';

class TrapSummaryHeader extends StatelessWidget {
  final TrapRepertoireMetrics metrics;

  const TrapSummaryHeader({super.key, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                StackedStat(
                  value: '${metrics.totalTraps}',
                  label: 'Total traps',
                ),
                StackedStat(
                  value: '${metrics.highQualityCount}',
                  label: 'High quality',
                ),
                StackedStat(
                  value: '${(metrics.avgReach * 100).toStringAsFixed(2)}%',
                  label: 'Avg reach',
                ),
                StackedStat(
                  value: '+${metrics.avgEvalGain.round()}cp',
                  label: 'Avg gain',
                ),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Expected Trap Value: '),
                Text(
                  '+${metrics.expectedTrapValue.toStringAsFixed(1)} cp/game',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(width: 4),
                const Tooltip(
                  message:
                      'Average centipawns gained per game from opponent\n'
                      'blunders at trap positions',
                  child: Icon(
                    Icons.info_outline,
                    size: 14,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
