/// Rows of an opening-explorer table, whatever the games came from.
///
/// Layout mirrors the Lichess explorer: SAN on the left, then the number of
/// games with the move's share of the position beside it, then a result bar
/// carrying its own percentages. Clicking a row plays the move on the board —
/// exactly what making the move on the board would do. Hovering echoes the
/// move as an arrow through [ExplorerMoveRow.onHover]; the right-click menu
/// carries the rarer "add to repertoire" shortcut.
///
/// The live Lichess panel and the bughouse FICS book both draw their tables
/// out of these three widgets, so the two explorers in the app are one table
/// with two data sources rather than two tables that drift apart. The counts
/// are plain integers here for that reason: neither source's model is the
/// other's.
///
/// Every row is the same fixed height, and hovering changes only the row's
/// tint — never its size — so the list holds still under the pointer.
library;

import 'package:flutter/material.dart';

import '../../models/explorer_response.dart';
import '../../models/opening_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../opening_tree/win_draw_loss_bar.dart';

/// Column widths shared by the header, the move rows and the totals row so
/// they line up as one table.
abstract final class ExplorerColumns {
  static const double san = 60;
  static const double games = 56;
  static const double share = 40;
  static const double gap = 10;
  static const double rowHeight = 26;
  static const double barHeight = 18;
  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 10);
}

/// Compact game counts: 1234 → "1.2k", 1_200_000 → "1.2M".
String formatExplorerCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// A move's share of the position, as the share column prints it.
///
/// Rounds, but never to `0%`: a move in the table was played, and a zero
/// beside a four-figure game count reads as a broken column rather than as a
/// rare line.
String formatExplorerShare(double fraction) {
  final percent = fraction * 100;
  if (percent > 0 && percent < 0.5) return '<1%';
  return '${percent.round()}%';
}

class ExplorerMoveRow extends StatefulWidget {
  const ExplorerMoveRow({
    super.key,
    required this.san,
    this.seat,
    required this.games,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.playFraction,
    this.perspective = WdlPerspective.whiteBlack,
    this.tooltip,
    required this.onPlay,
    this.onAdd,
    this.onHover,
    this.inRepertoire = false,
  });

  /// A row for a move the Lichess explorer reported.
  ExplorerMoveRow.lichess({
    super.key,
    required ExplorerMove move,
    required this.onPlay,
    this.onAdd,
    this.onHover,
    this.inRepertoire = false,
  }) : san = move.san,
       seat = null,
       games = move.total,
       wins = move.white,
       draws = move.draws,
       losses = move.black,
       playFraction = move.playFraction,
       perspective = WdlPerspective.whiteBlack,
       tooltip = null;

  final String san;

  /// Who played it, when that is not obvious from the board — the seat letter
  /// in bughouse, where four people move. Printed muted before the SAN.
  final String? seat;

  /// Games in which the move was played: the count column. May exceed
  /// [wins] + [draws] + [losses] when some of those games never finished.
  final int games;

  /// The result split the bar is drawn from, read from whoever
  /// [perspective] says the protagonist is.
  final int wins;
  final int draws;
  final int losses;

  /// The move's share of every game from the position, in `[0, 1]`.
  final double playFraction;

  final WdlPerspective perspective;

  /// One line shown on hover, the way Lichess titles its bar with the average
  /// rating. Null for no tooltip.
  final String? tooltip;

  /// Play the move on the board (row click).
  final VoidCallback onPlay;

  /// When non-null, the right-click menu offers to add the move to the
  /// repertoire.
  final VoidCallback? onAdd;

  /// Pointer entered (true) or left (false) the row.
  final ValueChanged<bool>? onHover;

  /// Whether this move already exists in the repertoire (marks the SAN).
  final bool inRepertoire;

  @override
  State<ExplorerMoveRow> createState() => _ExplorerMoveRowState();
}

class _ExplorerMoveRowState extends State<ExplorerMoveRow> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    widget.onHover?.call(value);
  }

  @override
  void dispose() {
    // A row rebuilt away under the pointer never gets onExit; don't leave
    // its arrow stranded on the board.
    if (_hovered) widget.onHover?.call(false);
    super.dispose();
  }

  Future<void> _showContextMenu(Offset globalPosition) async {
    final onAdd = widget.onAdd;
    if (onAdd == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final rect = RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    );
    final choice = await showMenu<String>(
      context: context,
      position: rect,
      items: [
        PopupMenuItem(
          value: 'add',
          enabled: !widget.inRepertoire,
          height: 36,
          child: Text(
            widget.inRepertoire
                ? '${widget.san} is already in the repertoire'
                : 'Add ${widget.san} to repertoire',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
    if (choice == 'add') onAdd();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = widget.playFraction.clamp(0.0, 1.0);

    Widget row = Container(
      height: ExplorerColumns.rowHeight,
      color: _hovered ? theme.colorScheme.surfaceContainerHighest : null,
      child: DecoratedBox(
        // Frequency "heat" matching the repertoire tree rows: a heavier
        // left-anchored wash for more-played moves. Composited over the
        // hover tint so neither replaces the other.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            stops: [fraction, fraction],
            colors: const [AppColors.rowStripe, Colors.transparent],
          ),
        ),
        child: Padding(
          padding: ExplorerColumns.padding,
          child: Row(
            children: [
              SizedBox(
                width: ExplorerColumns.san,
                child: Row(
                  children: [
                    if (widget.seat != null)
                      SizedBox(
                        width: 14,
                        child: Text(
                          widget.seat!,
                          style: AppTextStyles.monoDense.copyWith(
                            color: AppColors.onSurfaceMuted,
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        widget.san,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.inRepertoire)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Tooltip(
                          message: 'In repertoire',
                          child: Icon(
                            Icons.check,
                            size: 12,
                            color: AppColors.onSurfaceMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: ExplorerColumns.games,
                child: Text(
                  formatExplorerCount(widget.games),
                  textAlign: TextAlign.right,
                  style: AppTextStyles.caption,
                ),
              ),
              SizedBox(
                width: ExplorerColumns.share,
                child: Text(
                  formatExplorerShare(widget.playFraction),
                  textAlign: TextAlign.right,
                  style: AppTextStyles.caption,
                ),
              ),
              const SizedBox(width: ExplorerColumns.gap),
              Expanded(
                child: WinDrawLossBar(
                  wins: widget.wins,
                  draws: widget.draws,
                  losses: widget.losses,
                  perspective: widget.perspective,
                  height: ExplorerColumns.barHeight,
                  showPercentages: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      row = Tooltip(
        message: widget.tooltip!,
        waitDuration: const Duration(milliseconds: 400),
        child: row,
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPlay,
        onSecondaryTapUp: widget.onAdd == null
            ? null
            : (d) => _showContextMenu(d.globalPosition),
        child: row,
      ),
    );
  }
}

/// Column captions above the move rows.
class ExplorerTableHeader extends StatelessWidget {
  const ExplorerTableHeader({
    super.key,
    this.barCaption = 'White / Draw / Black',
    this.gamesTooltip =
        'Games in which the move was played, and its share of all '
        'games from this position',
  });

  /// What the bar's three segments are — whose wins are on the left.
  final String barCaption;

  final String gamesTooltip;

  static const _style = TextStyle(
    fontSize: 12,
    color: AppColors.onSurfaceMuted,
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: ExplorerColumns.padding,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: ExplorerColumns.san,
            child: Text('Move', style: _style),
          ),
          Tooltip(
            message: gamesTooltip,
            child: const SizedBox(
              width: ExplorerColumns.games + ExplorerColumns.share,
              child: Text('Games', textAlign: TextAlign.right, style: _style),
            ),
          ),
          const SizedBox(width: ExplorerColumns.gap),
          Expanded(
            child: Text(barCaption, textAlign: TextAlign.center, style: _style),
          ),
        ],
      ),
    );
  }
}

/// The Σ row: every game from this position, whatever was played.
class ExplorerTotalsRow extends StatelessWidget {
  const ExplorerTotalsRow({
    super.key,
    required this.games,
    required this.wins,
    required this.draws,
    required this.losses,
    this.perspective = WdlPerspective.whiteBlack,
  });

  /// The Σ row under a Lichess explorer table.
  ExplorerTotalsRow.lichess({super.key, required ExplorerResponse response})
    : games = response.totalGames,
      wins = response.whiteTotal,
      draws = response.drawTotal,
      losses = response.blackTotal,
      perspective = WdlPerspective.whiteBlack;

  /// Every game from the position, listed continuation or not.
  final int games;

  final int wins;
  final int draws;
  final int losses;
  final WdlPerspective perspective;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: ExplorerColumns.rowHeight,
      padding: ExplorerColumns.padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: const Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: ExplorerColumns.san,
            child: Tooltip(
              message: 'All games from this position',
              child: Text(
                'Σ',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          SizedBox(
            width: ExplorerColumns.games,
            child: Text(
              formatExplorerCount(games),
              textAlign: TextAlign.right,
              style: AppTextStyles.caption,
            ),
          ),
          const SizedBox(
            width: ExplorerColumns.share,
            child: Text(
              '100%',
              textAlign: TextAlign.right,
              style: AppTextStyles.caption,
            ),
          ),
          const SizedBox(width: ExplorerColumns.gap),
          Expanded(
            child: WinDrawLossBar(
              wins: wins,
              draws: draws,
              losses: losses,
              perspective: perspective,
              height: ExplorerColumns.barHeight,
              showPercentages: true,
            ),
          ),
        ],
      ),
    );
  }
}
