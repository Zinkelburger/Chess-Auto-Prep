import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import '../../theme/app_colors.dart';
import 'coverage_annotation.dart';
import 'win_draw_loss_bar.dart';

/// A single child move row in the opening tree list.
class OpeningTreeMoveRow extends StatelessWidget {
  final OpeningTreeNode node;
  final int parentGamesPlayed;
  final CoverageStatus? coverageStatus;
  final VoidCallback? onTap;
  final WdlPerspective perspective;

  const OpeningTreeMoveRow({
    super.key,
    required this.node,
    required this.parentGamesPlayed,
    this.coverageStatus,
    this.onTap,
    this.perspective = WdlPerspective.playerIsWhite,
  });

  @override
  Widget build(BuildContext context) {
    final playedPercent = parentGamesPlayed > 0
        ? (node.gamesPlayed / parentGamesPlayed * 100)
        : 0.0;

    // Score from the displayed point of view: the protagonist's when known,
    // otherwise White's (shown without a good/bad color).
    final displayRate = perspective == WdlPerspective.playerIsBlack
        ? 1.0 - node.winRate
        : node.winRate;

    Color winRateColor;
    if (perspective == WdlPerspective.whiteBlack) {
      winRateColor = AppColors.inkSoft;
    } else if (displayRate >= 0.55) {
      winRateColor = AppColors.success;
    } else if (displayRate >= 0.45) {
      winRateColor = AppColors.warning;
    } else {
      winRateColor = AppColors.danger;
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: const Border(
            bottom: BorderSide(color: AppColors.divider, width: 0.5),
          ),
          // Frequency "heat": more-played moves get a heavier left-anchored
          // wash, so the eye weights common continuations. Shared visual
          // language with the live opening explorer rows.
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            stops: [
              (playedPercent / 100).clamp(0.0, 1.0),
              (playedPercent / 100).clamp(0.0, 1.0),
            ],
            colors: [Colors.white.withValues(alpha: 0.05), Colors.transparent],
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
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceSoft,
                    ),
                  ),
                ),
                Text(
                  '${(displayRate * 100).toStringAsFixed(1)}%',
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
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: WinDrawLossBar(
                    wins: node.wins,
                    draws: node.draws,
                    losses: node.losses,
                    perspective: perspective,
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
