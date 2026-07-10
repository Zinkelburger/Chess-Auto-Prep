import 'package:flutter/material.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/coverage_helpers.dart';
import '../../utils/pgn_utils.dart' as pgn_utils;
import '../../models/repertoire_line.dart';

/// Coverage progress, summary stats, and filtered-line counts.
class LineMetricsPanel extends StatelessWidget {
  final bool showCoverageProgress;
  final double? coverageProgress;
  final String? coverageProgressMessage;

  final CoverageResult? coverageResult;
  final Map<String, LineCoverageInfo> lineCoverage;

  final List<RepertoireLine> filteredLines;
  final List<String> currentMoveSequence;
  final void Function(List<String> moveSequence)? onNavigateToPosition;

  const LineMetricsPanel({
    super.key,
    this.showCoverageProgress = false,
    this.coverageProgress,
    this.coverageProgressMessage,
    this.coverageResult,
    required this.lineCoverage,
    required this.filteredLines,
    this.currentMoveSequence = const [],
    this.onNavigateToPosition,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCoverageProgress)
          _CoverageProgressBar(
            progress: coverageProgress,
            message: coverageProgressMessage,
          ),
        if (coverageResult != null)
          _CoverageSummaryBar(
            lineCoverage: lineCoverage,
            coverageResult: coverageResult!,
            onNavigateToPosition: onNavigateToPosition,
          ),
        _StatsBar(
          filteredLines: filteredLines,
          currentMoveSequence: currentMoveSequence,
        ),
      ],
    );
  }
}

class _CoverageProgressBar extends StatelessWidget {
  final double? progress;
  final String? message;

  const _CoverageProgressBar({this.progress, this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.2),
        border: Border(
          bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null)
            Text(
              message!,
              style: const TextStyle(fontSize: 11, color: AppColors.lichessDb),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.grey[800],
            minHeight: 4,
          ),
        ],
      ),
    );
  }
}

class _CoverageSummaryBar extends StatelessWidget {
  final Map<String, LineCoverageInfo> lineCoverage;
  final CoverageResult coverageResult;
  final void Function(List<String> moveSequence)? onNavigateToPosition;

  const _CoverageSummaryBar({
    required this.lineCoverage,
    required this.coverageResult,
    this.onNavigateToPosition,
  });

  @override
  Widget build(BuildContext context) {
    final total = lineCoverage.length;
    if (total == 0) return const SizedBox.shrink();

    double pct(int count) => (count / total) * 100;

    final covered = countCoveredLines(lineCoverage);
    final shallow = countShallowLines(lineCoverage);
    final deep = countDeepLines(lineCoverage);
    final totalUnaccounted = totalUnaccountedMoves(lineCoverage);

    final hasGaps = coverageResult.tooShallowLeaves.isNotEmpty ||
        coverageResult.unaccountedMoves.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(
          bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _CoverageStat(
                  label: 'Covered',
                  percent: pct(covered),
                  color: const Color(0xFF4CAF50)),
              const SizedBox(width: 4),
              Text('|',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              const SizedBox(width: 4),
              _CoverageStat(
                  label: 'Shallow',
                  percent: pct(shallow),
                  color: const Color(0xFFFFA726)),
              const SizedBox(width: 4),
              Text('|',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              const SizedBox(width: 4),
              _CoverageStat(
                  label: 'Deep',
                  percent: pct(deep),
                  color: const Color(0xFF42A5F5)),
              if (totalUnaccounted > 0) ...[
                const Spacer(),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFEF5350),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$totalUnaccounted unaccounted',
                      style: TextStyle(fontSize: 10, color: Colors.grey[300]),
                    ),
                  ],
                ),
              ],
            ],
          ),
          if (hasGaps && onNavigateToPosition != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                _GapButton(
                  label: 'Next Gap',
                  icon: Icons.skip_next,
                  onPressed: () {
                    final moves = coverageResult.findNextGap();
                    if (moves != null) {
                      onNavigateToPosition!(moves);
                    }
                  },
                ),
                const SizedBox(width: 8),
                _GapButton(
                  label: 'Biggest Gap',
                  icon: Icons.priority_high,
                  onPressed: () {
                    final moves = coverageResult.findBiggestGap();
                    if (moves != null) {
                      onNavigateToPosition!(moves);
                    }
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GapButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _GapButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
          side: BorderSide(color: Colors.grey[600]!),
        ),
      ),
    );
  }
}

class _CoverageStat extends StatelessWidget {
  final String label;
  final double percent;
  final Color color;

  const _CoverageStat({
    required this.label,
    required this.percent,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$label: ${percent.toStringAsFixed(1)}%',
          style: TextStyle(fontSize: 10, color: Colors.grey[300]),
        ),
      ],
    );
  }
}

class _StatsBar extends StatelessWidget {
  final List<RepertoireLine> filteredLines;
  final List<String> currentMoveSequence;

  const _StatsBar({
    required this.filteredLines,
    required this.currentMoveSequence,
  });

  @override
  Widget build(BuildContext context) {
    final matchingCount = filteredLines
        .where((l) => pgn_utils.lineMatchesPosition(l, currentMoveSequence))
        .length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.grey[900],
      child: Row(
        children: [
          Text(
            '${filteredLines.length} line${filteredLines.length == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
          ),
          if (currentMoveSequence.isNotEmpty) ...[
            Text(' • ', style: TextStyle(color: Colors.grey[600])),
            Text(
              '$matchingCount at current position',
              style: const TextStyle(fontSize: 11, color: AppColors.lichessDb),
            ),
          ],
        ],
      ),
    );
  }
}
