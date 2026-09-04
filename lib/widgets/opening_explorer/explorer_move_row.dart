/// Rows of the live opening explorer table.
///
/// Layout mirrors the Lichess explorer: SAN on the left, then the number of
/// games with the move's share of the position beside it, then a
/// white/grey/black result bar carrying its own percentages. Clicking a row
/// plays the move on the board — exactly what making the move on the board
/// would do. Hovering echoes the move as an arrow through [onHover]; the
/// right-click menu carries the rarer "add to repertoire" shortcut.
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

class ExplorerMoveRow extends StatefulWidget {
  const ExplorerMoveRow({
    super.key,
    required this.move,
    required this.onPlay,
    this.onAdd,
    this.onHover,
    this.inRepertoire = false,
  });

  final ExplorerMove move;

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
                ? '${widget.move.san} is already in the repertoire'
                : 'Add ${widget.move.san} to repertoire',
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
    final move = widget.move;

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
        child: Container(
          height: ExplorerColumns.rowHeight,
          color: _hovered ? theme.colorScheme.surfaceContainerHighest : null,
          child: DecoratedBox(
            // Frequency "heat" matching the repertoire tree rows: a heavier
            // left-anchored wash for more-played moves. Composited over the
            // hover tint so neither replaces the other.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: [
                  move.playFraction.clamp(0.0, 1.0),
                  move.playFraction.clamp(0.0, 1.0),
                ],
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
                        Text(
                          move.san,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
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
                      formatExplorerCount(move.total),
                      textAlign: TextAlign.right,
                      style: AppTextStyles.caption,
                    ),
                  ),
                  SizedBox(
                    width: ExplorerColumns.share,
                    child: Text(
                      '${move.playRate.round()}%',
                      textAlign: TextAlign.right,
                      style: AppTextStyles.caption,
                    ),
                  ),
                  const SizedBox(width: ExplorerColumns.gap),
                  Expanded(
                    child: WinDrawLossBar(
                      wins: move.white,
                      draws: move.draws,
                      losses: move.black,
                      perspective: WdlPerspective.whiteBlack,
                      height: ExplorerColumns.barHeight,
                      showPercentages: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Column captions above the move rows.
class ExplorerTableHeader extends StatelessWidget {
  const ExplorerTableHeader({super.key});

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
      child: const Row(
        children: [
          SizedBox(
            width: ExplorerColumns.san,
            child: Text('Move', style: _style),
          ),
          Tooltip(
            message:
                'Games in which the move was played, and its share of all '
                'games from this position',
            child: SizedBox(
              width: ExplorerColumns.games + ExplorerColumns.share,
              child: Text('Games', textAlign: TextAlign.right, style: _style),
            ),
          ),
          SizedBox(width: ExplorerColumns.gap),
          Expanded(
            child: Text(
              'White / Draw / Black',
              textAlign: TextAlign.center,
              style: _style,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Σ row: every game from this position, whatever was played.
class ExplorerTotalsRow extends StatelessWidget {
  const ExplorerTotalsRow({super.key, required this.response});

  final ExplorerResponse response;

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
              formatExplorerCount(response.totalGames),
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
              wins: response.whiteTotal,
              draws: response.drawTotal,
              losses: response.blackTotal,
              perspective: WdlPerspective.whiteBlack,
              height: ExplorerColumns.barHeight,
              showPercentages: true,
            ),
          ),
        ],
      ),
    );
  }
}
