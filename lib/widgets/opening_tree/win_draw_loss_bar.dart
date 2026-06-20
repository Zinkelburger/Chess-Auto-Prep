import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Compact win / draw / loss bar (green / grey / red).
///
/// Shared between the opening explorer's move rows and the games-draft review
/// so both render the same result breakdown. Segments are sized by raw counts;
/// a segment is omitted entirely when its count is zero.
class WinDrawLossBar extends StatelessWidget {
  const WinDrawLossBar({
    super.key,
    required this.wins,
    required this.draws,
    required this.losses,
    this.height = 16,
  });

  final int wins;
  final int draws;
  final int losses;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: Row(
          children: [
            if (wins > 0)
              Expanded(flex: wins, child: Container(color: AppColors.evalPositive)),
            if (draws > 0)
              Expanded(flex: draws, child: Container(color: Colors.grey[600])),
            if (losses > 0)
              Expanded(flex: losses, child: Container(color: AppColors.evalNegative)),
          ],
        ),
      ),
    );
  }
}
