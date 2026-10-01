import 'package:flutter/material.dart';

import '../../chess/book/book_check.dart';
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import 'player_book.dart';

/// The My book tab: the player's games walked through the book in use for
/// the other colour, and the places they left it — a reply the book does
/// not answer, or a line that goes on after the book stops. A row opens its
/// game at that move.
class PlayerBookPane extends StatelessWidget {
  const PlayerBookPane({
    super.key,
    required this.book,
    required this.onOpen,
    required this.onBooks,
  });
  final PlayerBook book;
  final ValueChanged<PlayerBookGap> onOpen;
  final VoidCallback onBooks;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: book,
    builder: (context, _) {
      final theme = Theme.of(context);
      final status = book.status;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, 0),
            child: Row(
              children: [
                FilledButton(
                  onPressed: book.busy ? null : book.check,
                  child: Text(book.busy ? 'Checking…' : 'Check my book'),
                ),
                const SizedBox(width: Space.s),
                TextButton(
                  onPressed: onBooks,
                  child: const Text('Choose book'),
                ),
              ],
            ),
          ),
          if (book.busy)
            const Padding(
              padding: EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
              child: LinearProgressIndicator(minHeight: progressLineHeight),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.m,
              Space.s,
              Space.m,
              Space.s,
            ),
            child: Text(
              status ??
                  'Finds this player’s replies your book in use does not '
                      'answer.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: book.gaps.length,
              itemExtent: puzzleRowHeight,
              itemBuilder: (context, i) =>
                  _GapRow(book: book, gap: book.gaps[i], onOpen: onOpen),
            ),
          ),
        ],
      );
    },
  );
}

/// One game that left the book: the move that did it and which kind of gap
/// it is, then the game.
class _GapRow extends StatelessWidget {
  const _GapRow({required this.book, required this.gap, required this.onOpen});

  final PlayerBook book;
  final PlayerBookGap gap;
  final ValueChanged<PlayerBookGap> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final game = book.analysis.corpus!.games[gap.game];
    return InkWell(
      onTap: () => onOpen(gap),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  displaySan(context, gap.gap.played),
                  style: monoText.copyWith(color: theme.colorScheme.onSurface),
                ),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Text(
                    gap.gap.kind == Deviation.theirs
                        ? 'Unanswered reply'
                        : 'Past the end of the book',
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Text(
              '${game.title} · ${game.date}',
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
