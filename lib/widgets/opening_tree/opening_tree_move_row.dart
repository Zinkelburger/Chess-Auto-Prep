import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'coverage_annotation.dart';
import 'win_draw_loss_bar.dart';

/// A single child move row in the opening tree list.
///
/// [entry] is a transposition-aware group: its stats are summed over every
/// path that reaches this continuation. Reads like an explorer row: the move,
/// how often it was played, the score from the displayed point of view, and a
/// result bar carrying its own percentages (exact counts in its tooltip).
class OpeningTreeMoveRow extends StatefulWidget {
  final PositionGroup entry;
  final int parentGamesPlayed;
  final CoverageStatus? coverageStatus;
  final VoidCallback? onTap;

  /// Pointer entered (true) or left (false) the row — lets the host echo the
  /// move as an arrow on the board.
  final ValueChanged<bool>? onHover;
  final WdlPerspective perspective;

  /// Cumulative chance the analyzed player reaches the position after this
  /// move (see [ReachEstimate]). Only set when this move is theirs to make;
  /// null hides the annotation.
  final ReachEstimate? reachEstimate;

  const OpeningTreeMoveRow({
    super.key,
    required this.entry,
    required this.parentGamesPlayed,
    this.coverageStatus,
    this.onTap,
    this.onHover,
    this.perspective = WdlPerspective.playerIsWhite,
    this.reachEstimate,
  });

  @override
  State<OpeningTreeMoveRow> createState() => _OpeningTreeMoveRowState();
}

class _OpeningTreeMoveRowState extends State<OpeningTreeMoveRow> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    widget.onHover?.call(value);
  }

  @override
  void dispose() {
    if (_hovered) widget.onHover?.call(false);
    super.dispose();
  }

  /// Exact result counts, worded from the displayed point of view.
  String _countsTooltip(PositionGroup entry) {
    switch (widget.perspective) {
      case WdlPerspective.whiteBlack:
        return '${entry.wins} white wins · ${entry.draws} draws · '
            '${entry.losses} black wins';
      case WdlPerspective.playerIsBlack:
        return '${entry.losses} wins · ${entry.draws} draws · '
            '${entry.wins} losses';
      case WdlPerspective.playerIsWhite:
        return '${entry.wins} wins · ${entry.draws} draws · '
            '${entry.losses} losses';
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final perspective = widget.perspective;
    final playedPercent = widget.parentGamesPlayed > 0
        ? (entry.gamesPlayed / widget.parentGamesPlayed * 100)
        : 0.0;

    // Score from the displayed point of view: the protagonist's when known,
    // otherwise White's (shown without a good/bad color).
    final displayRate = perspective == WdlPerspective.playerIsBlack
        ? 1.0 - entry.winRate
        : entry.winRate;

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

    final reach = widget.reachEstimate;
    final frequency = entry.viaTransposition
        ? '${entry.gamesPlayed} games (transp.)'
        : '${entry.gamesPlayed} games · ${playedPercent.round()}%';

    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: _hovered
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: const Border(
                bottom: BorderSide(color: AppColors.divider, width: 0.5),
              ),
              // Frequency "heat": more-played moves get a heavier
              // left-anchored wash, so the eye weights common continuations.
              // Shared visual language with the live opening explorer rows.
              gradient: LinearGradient(
                stops: [
                  (playedPercent / 100).clamp(0.0, 1.0),
                  (playedPercent / 100).clamp(0.0, 1.0),
                ],
                colors: const [AppColors.rowStripe, Colors.transparent],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (widget.coverageStatus != null)
                        CoverageIndicator(status: widget.coverageStatus!),
                      SizedBox(
                        width: 60,
                        child: Text(
                          entry.viaTransposition
                              ? '${entry.move}≈'
                              : entry.move,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            fontFamily: AppTextStyles.monoFamily,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          reach == null
                              ? frequency
                              : '$frequency · ${reach.percentLabel}% reached',
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.caption,
                        ),
                      ),
                      if (entry.hasWdl)
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
                  if (entry.hasWdl) ...[
                    const SizedBox(height: 5),
                    Tooltip(
                      message: _countsTooltip(entry),
                      waitDuration: const Duration(milliseconds: 600),
                      child: WinDrawLossBar(
                        wins: entry.wins,
                        draws: entry.draws,
                        losses: entry.losses,
                        perspective: perspective,
                        showPercentages: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
