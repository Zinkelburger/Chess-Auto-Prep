import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class BuildProgressDisplay extends StatelessWidget {
  const BuildProgressDisplay({
    super.key,
    required this.nodes,
    required this.isGenerating,
    required this.isPaused,
    required this.elapsedMs,
    required this.nodesPerMinute,
    required this.currentDepth,
    required this.maxPlyConfig,
    required this.unexploredAtDepth,
    required this.totalAtDepth,
    required this.etaDepthSec,
  });

  final int nodes;
  final bool isGenerating;
  final bool isPaused;
  final int elapsedMs;
  final double? nodesPerMinute;
  final int currentDepth;
  final int maxPlyConfig;
  final int unexploredAtDepth;
  final int totalAtDepth;
  final int? etaDepthSec;

  static String formatEta(int sec) {
    if (sec < 60) return '${sec}s';
    if (sec < 3600) return '${(sec / 60).ceil()}m';
    final h = sec ~/ 3600;
    final m = ((sec % 3600) / 60).ceil();
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final secs = elapsedMs / 1000.0;
    final elapsed = secs >= 60
        ? '${(secs / 60).floor()}m ${(secs % 60).toStringAsFixed(0)}s'
        : '${secs.toStringAsFixed(1)}s';

    final explored = totalAtDepth - unexploredAtDepth;
    final rateStr = nodesPerMinute != null
        ? '${nodesPerMinute!.toStringAsFixed(0)} nodes/min'
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isGenerating && !isPaused)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (isPaused)
                const Icon(Icons.pause_circle,
                    size: 14, color: AppColors.warning),
              const SizedBox(width: 6),
              Text(
                '$nodes nodes',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (rateStr != null) ...[
                const SizedBox(width: 10),
                Text(
                  rateStr,
                  style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                ),
              ],
              const Spacer(),
              Text(
                elapsed,
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              ),
            ],
          ),
          if (isGenerating && currentDepth > 0) ...[
            const SizedBox(height: 6),
            Text(
              () {
                final parts = <String>[
                  'Depth $currentDepth/$maxPlyConfig',
                  '$explored / $totalAtDepth explored',
                  if (unexploredAtDepth > 0) '$unexploredAtDepth remaining',
                  if (etaDepthSec != null) '~${formatEta(etaDepthSec!)}',
                ];
                return parts.join(' · ');
              }(),
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
          ],
        ],
      ),
    );
  }
}
