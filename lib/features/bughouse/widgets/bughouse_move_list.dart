import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_state.dart';

/// One board's movetext, numbered the way that board counts.
///
/// This is how FICS did it, and it is the only arrangement that reads. On FICS
/// a bughouse table was not one game with one score; it was two games, each
/// with its own number, its own clock and its own movetext, joined only by the
/// partnership. `1. e4 Nf6 2. e5 d5` on one board and `1. d4 d5 2. c4 dxc4` on
/// the other, drops written `P@f7`. Interleaving them into a single column
/// destroys the one thing a reader needs — each board's own move numbers — to
/// preserve a global order that was never meaningful anyway, because the two
/// boards are ordered by four clocks and not by turns.
///
/// The entry order is not thrown away: it is still the index the cursor moves
/// along, so stepping back and forward walks the game as it was played, across
/// both boards. It is just not what the eye has to read. And because each
/// column belongs to one board, it is drawn under that board rather than
/// pooled with the other one in a panel across the screen.
class BughouseBoardMovetext extends StatelessWidget {
  const BughouseBoardMovetext({
    super.key,
    required this.controller,
    required this.which,
  });

  final BughouseController controller;
  final BughouseBoard which;

  /// Fixed, not "as tall as the moves need".
  ///
  /// The board above it is sized from the height left over (see the pane's
  /// `_Boards.fit`), so a movetext that grew with the game would shrink the
  /// boards mid-game or push the controls off the bottom. Three lines, and it
  /// scrolls inside itself after that.
  static const double height = 60;

  @override
  Widget build(BuildContext context) {
    final entries = controller.history.movetextOn(which);
    final cursor = controller.history.cursor;

    return Container(
      height: height,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.pgnSurface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: entries.isEmpty
          ? const Text(
              'No moves on this board yet.',
              style: AppTextStyles.caption,
            )
          : SingleChildScrollView(
              child: Wrap(
                spacing: 5,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final entry in entries) ...[
                    // A number is printed before white's move, and before a
                    // black move that opens the column — exactly the movetext
                    // rule, so the two boards read as two normal games.
                    if (entry.showsNumber)
                      Text(
                        entry.ply.numberLabel,
                        style: AppTextStyles.monoDense.copyWith(
                          color: AppColors.pgnMoveNumber,
                        ),
                      ),
                    _MoveChip(
                      ply: entry.ply,
                      selected: cursor == entry.index + 1,
                      onTap: () => controller.goTo(entry.index + 1),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _MoveChip extends StatelessWidget {
  const _MoveChip({
    required this.ply,
    required this.selected,
    required this.onTap,
  });

  final BughousePly ply;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: selected ? AppColors.pgnMoveCurrentBg : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          ply.san,
          style: AppTextStyles.monoDense.copyWith(
            color: selected ? AppColors.pgnMoveCurrentFg : AppColors.pgnMove,
          ),
        ),
      ),
    );
  }
}

/// Walking the line — one strip under both boards, because the cursor is one
/// cursor across the pair even though the movetext is two columns.
class BughouseLineControls extends StatelessWidget {
  const BughouseLineControls({super.key, required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final history = controller.history;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _NavButton(
          icon: Icons.first_page,
          tooltip: 'Start of the line (Home)',
          onPressed: history.canGoBack ? controller.toStart : null,
        ),
        _NavButton(
          icon: Icons.chevron_left,
          tooltip: 'Back one ply (←)',
          onPressed: history.canGoBack ? controller.back : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${history.cursor} / ${history.length}',
            style: AppTextStyles.monoDense.copyWith(
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ),
        _NavButton(
          icon: Icons.chevron_right,
          tooltip: 'Forward one ply (→)',
          onPressed: history.canGoForward ? controller.forward : null,
        ),
        _NavButton(
          icon: Icons.last_page,
          tooltip: 'End of the line (End)',
          onPressed: history.canGoForward ? controller.toEnd : null,
        ),
        const SizedBox(width: 12),
        _NavButton(
          icon: Icons.undo,
          tooltip: 'Take the last move back',
          onPressed: history.canGoBack ? controller.undo : null,
        ),
        _CopyTableMenu(controller: controller),
      ],
    );
  }
}

/// Copying the *pair*: both boards at once, as moves or as a position.
///
/// The per-board copy lives in each board's header, beside that board's own
/// movetext, because a board is a game and its moves are that game's. What is
/// left over is everything that only exists as a pair — the two columns
/// together, and the dual FEN, which is one string describing two positions
/// and has no home on either board. So it sits under both of them, on the
/// strip that already belongs to the pair rather than to either half.
class _CopyTableMenu extends StatelessWidget {
  const _CopyTableMenu({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final entries = [
      AppMenuEntry(
        label: "Both boards' moves",
        icon: Icons.notes,
        enabled: !controller.history.isEmpty,
        onRun: () => copyToClipboard(
          context,
          controller.history.tableMovetext,
          successMessage: "Both boards' moves copied",
        ),
      ),
      AppMenuEntry(
        label: 'Dual FEN',
        icon: Icons.grid_on,
        // The position at the cursor, not the one at the end of the line:
        // what is copied is what the two boards are showing.
        onRun: () => copyToClipboard(
          context,
          controller.state.dualFen,
          successMessage: 'Dual FEN copied',
        ),
        hint:
            'Both positions as one string, `<board 1>|<board 2>` — the form '
            'the engine and the setup panel read back.',
      ),
    ];
    // Sized to the nav buttons beside it: a popup button's default padding
    // is larger than an icon button's, which stood this one proud of the row.
    return SizedBox(
      width: 34,
      height: 32,
      child: PopupMenuButton<int>(
        icon: const Icon(Icons.copy),
        iconSize: 18,
        padding: EdgeInsets.zero,
        tooltip: 'Copy the table',
        onSelected: (i) => entries[i].onRun(),
        itemBuilder: (_) => [
          for (var i = 0; i < entries.length; i++)
            PopupMenuItem<int>(
              value: i,
              enabled: entries[i].enabled,
              child: AppMenuEntryRow(entry: entries[i]),
            ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
