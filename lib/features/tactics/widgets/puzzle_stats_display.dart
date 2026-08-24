import 'package:flutter/material.dart';

import '../models/tactics_position.dart';
import '../../../theme/app_colors.dart';

/// Compact success/review stats for a tactics position.
class PuzzleStatsDisplay extends StatelessWidget {
  const PuzzleStatsDisplay({
    super.key,
    required this.position,
    this.width = 60,
    this.fontSize = 12,
  });

  final TacticsPosition position;
  final double width;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final pos = position;
    return SizedBox(
      width: width,
      child: Text(
        pos.reviewCount > 0
            ? '${pos.successCount}/${pos.reviewCount} ${(pos.successRate * 100).toStringAsFixed(0)}%'
            : 'new',
        textAlign: TextAlign.right,
        // One ink. A green/amber/red success rate was a traffic light on a
        // number that already says the same thing — and it graded the user on
        // a column they scan past, which is the opposite of restful.
        style: TextStyle(
          fontSize: fontSize,
          color: pos.reviewCount == 0
              ? AppColors.onSurfaceMuted
              : AppColors.onSurfaceSoft,
        ),
      ),
    );
  }
}
