import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import '../../theme/app_colors.dart';
import 'coverage_annotation.dart';

/// A single child move row in the opening tree list.
class OpeningTreeMoveRow extends StatelessWidget {
  final OpeningTreeNode node;
  final int parentGamesPlayed;
  final CoverageStatus? coverageStatus;
  final VoidCallback? onTap;

  const OpeningTreeMoveRow({
    super.key,
    required this.node,
    required this.parentGamesPlayed,
    this.coverageStatus,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final playedPercent = parentGamesPlayed > 0
        ? (node.gamesPlayed / parentGamesPlayed * 100)
        : 0.0;

    Color winRateColor;
    if (node.winRate >= 0.55) {
      winRateColor = Colors.green;
    } else if (node.winRate >= 0.45) {
      winRateColor = Colors.orange;
    } else {
      winRateColor = Colors.red;
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.grey[800]!,
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (coverageStatus != null)
                  CoverageIndicator(status: coverageStatus!),
                SizedBox(
                  width: 60,
                  child: Text(
                    node.move,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${node.gamesPlayed} games (${playedPercent.toStringAsFixed(1)}%)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[400],
                    ),
                  ),
                ),
                Text(
                  '${node.winRatePercent.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: winRateColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 100,
                  child: Text(
                    '${node.wins}-${node.draws}-${node.losses}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _OpeningTreeWinRateBar(node: node),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Visual win rate bar similar to openingtree.com.
class _OpeningTreeWinRateBar extends StatelessWidget {
  final OpeningTreeNode node;

  const _OpeningTreeWinRateBar({required this.node});

  @override
  Widget build(BuildContext context) {
    final winPercent =
        node.gamesPlayed > 0 ? node.wins / node.gamesPlayed : 0.0;
    final drawPercent =
        node.gamesPlayed > 0 ? node.draws / node.gamesPlayed : 0.0;
    final lossPercent =
        node.gamesPlayed > 0 ? node.losses / node.gamesPlayed : 0.0;

    return Container(
      height: 16,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: Row(
          children: [
            if (winPercent > 0)
              Expanded(
                flex: (winPercent * 100).round(),
                child: Container(
                  color: AppColors.evalPositive,
                ),
              ),
            if (drawPercent > 0)
              Expanded(
                flex: (drawPercent * 100).round(),
                child: Container(
                  color: Colors.grey[600],
                ),
              ),
            if (lossPercent > 0)
              Expanded(
                flex: (lossPercent * 100).round(),
                child: Container(
                  color: AppColors.evalNegative,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
