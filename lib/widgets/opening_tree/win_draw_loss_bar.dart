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
/// With [showPercentages] each segment carries its share as a label, the way
/// Lichess prints "48% · 31% · 21%" inside its explorer bars; a segment too
/// narrow to fit its label stays unlabelled rather than overflowing.
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
    this.showPercentages = false,
  });

  final int wins;
  final int draws;
  final int losses;
  final WdlPerspective perspective;
  final double height;
  final bool showPercentages;

  static const _whiteSegment = AppColors.wdlWhite;
  static const _blackSegment = AppColors.wdlBlack;

  /// Label font size; the bar hides a label whose segment cannot fit it.
  static const double labelFontSize = 10;

  int get _total => wins + draws + losses;

  /// Whole-number percentage of [count] over the bar's total.
  int percentOf(int count) => _total == 0 ? 0 : (count * 100 / _total).round();

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Row(
              children: [
                if (wins > 0)
                  Expanded(flex: wins, child: _segment(wins, winColor, width)),
                if (draws > 0)
                  Expanded(
                    flex: draws,
                    child: _segment(draws, AppColors.wdlDraw, width),
                  ),
                if (losses > 0)
                  Expanded(
                    flex: losses,
                    child: _segment(losses, lossColor, width),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _segment(int count, Color fill, double barWidth) {
    if (!showPercentages || _total == 0) return ColoredBox(color: fill);
    final label = '${percentOf(count)}%';
    // Roughly 0.6em per glyph plus breathing room; a label that would not
    // fit is dropped, not squeezed.
    final needed = label.length * labelFontSize * 0.62 + 6;
    final available = barWidth * count / _total;
    if (!barWidth.isFinite || available < needed) {
      return ColoredBox(color: fill);
    }
    return ColoredBox(
      color: fill,
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontSize: labelFontSize,
            fontWeight: FontWeight.w600,
            height: 1,
            color: _inkOn(fill),
          ),
        ),
      ),
    );
  }

  /// Dark ink on the bright fills (white segment, green/red), light ink on
  /// the grey and near-black ones — see [AppColors.onWarning].
  static Color _inkOn(Color fill) =>
      fill == AppColors.wdlDraw || fill == _blackSegment
      ? AppColors.ink
      : AppColors.onWarning;
}
