import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import '../../theme/app_colors.dart';

/// Compact win / draw / loss result bar.
///
/// Segments are always laid out wins–draws–losses (i.e. White's score on the
/// left when the stats are from White's perspective); only the coloring
/// changes with [perspective]:
/// - [WdlPerspective.playerIsWhite]: green / grey / red (wins are good).
/// - [WdlPerspective.playerIsBlack]: red / grey / green (wins are the
///   opponent's).
/// - [WdlPerspective.whiteBlack]: lichess-style white / grey / near-black —
///   no value judgment when we don't know whose games these are.
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
    this.perspective = WdlPerspective.playerIsWhite,
    this.height = 16,
  });

  final int wins;
  final int draws;
  final int losses;
  final WdlPerspective perspective;
  final double height;

  static const _whiteSegment = AppColors.wdlWhite;
  static const _blackSegment = AppColors.wdlBlack;

  @override
  Widget build(BuildContext context) {
    final (winColor, lossColor) = switch (perspective) {
      WdlPerspective.playerIsWhite => (
        AppColors.evalPositive,
        AppColors.evalNegative,
      ),
      WdlPerspective.playerIsBlack => (
        AppColors.evalNegative,
        AppColors.evalPositive,
      ),
      WdlPerspective.whiteBlack => (_whiteSegment, _blackSegment),
    };

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: AppColors.outline, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: Row(
          children: [
            if (wins > 0)
              Expanded(
                flex: wins,
                child: Container(color: winColor),
              ),
            if (draws > 0)
              Expanded(
                flex: draws,
                child: Container(color: AppColors.wdlDraw),
              ),
            if (losses > 0)
              Expanded(
                flex: losses,
                child: Container(color: lossColor),
              ),
          ],
        ),
      ),
    );
  }
}
