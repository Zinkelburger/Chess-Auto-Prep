import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_state.dart';

/// The line played so far, as two ordinary move lists — one per board.
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
/// both boards. It is just not what the eye has to read.
class BughouseMoveList extends StatelessWidget {
  const BughouseMoveList({super.key, required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final history = controller.history;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('Line', style: AppTextStyles.subtitle),
            const Spacer(),
            _NavButton(
              icon: Icons.first_page,
              tooltip: 'Start',
              onPressed: history.canGoBack ? controller.toStart : null,
            ),
            _NavButton(
              icon: Icons.chevron_left,
              tooltip: 'Back',
              onPressed: history.canGoBack ? controller.back : null,
            ),
            _NavButton(
              icon: Icons.chevron_right,
              tooltip: 'Forward',
              onPressed: history.canGoForward ? controller.forward : null,
            ),
            _NavButton(
              icon: Icons.last_page,
              tooltip: 'End',
              onPressed: history.canGoForward ? controller.toEnd : null,
            ),
            _NavButton(
              icon: Icons.undo,
              tooltip: 'Undo last move',
              onPressed: history.canGoBack ? controller.undo : null,
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (history.isEmpty)
          const Text(
            'No moves yet. Play on either board, or drop a reserve piece by '
            'clicking it and then a square.',
            style: AppTextStyles.caption,
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final which in BughouseBoard.values)
                    _BoardMovetext(controller: controller, which: which),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One board's movetext, numbered as that board counts.
class _BoardMovetext extends StatelessWidget {
  const _BoardMovetext({required this.controller, required this.which});

  final BughouseController controller;
  final BughouseBoard which;

  @override
  Widget build(BuildContext context) {
    final entries = _entriesFor(controller.history, which);
    final cursor = controller.history.cursor;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${which.label} · we play '
            '${controller.state.sideOn(which) == Side.white ? 'white' : 'black'}',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 2),
          if (entries.isEmpty)
            const Text('—', style: AppTextStyles.monoDense)
          else
            Wrap(
              spacing: 4,
              runSpacing: 2,
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
                        color: AppColors.onSurfaceMuted,
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
        ],
      ),
    );
  }

  /// This board's plies, each keeping the index it has in the whole line so a
  /// click still navigates the game as it was played.
  static List<_Entry> _entriesFor(
    BughouseHistory history,
    BughouseBoard which,
  ) {
    final entries = <_Entry>[];
    for (var i = 0; i < history.length; i++) {
      final ply = history.plies[i];
      if (ply.board != which) continue;
      entries.add(
        _Entry(
          ply: ply,
          index: i,
          showsNumber: ply.side == Side.white || entries.isEmpty,
        ),
      );
    }
    return entries;
  }
}

class _Entry {
  const _Entry({
    required this.ply,
    required this.index,
    required this.showsNumber,
  });

  final BughousePly ply;

  /// Position in the whole line, which is what the cursor indexes.
  final int index;
  final bool showsNumber;
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
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          ply.san,
          style: AppTextStyles.monoDense.copyWith(
            color: selected ? scheme.onPrimaryContainer : AppColors.ink,
          ),
        ),
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
