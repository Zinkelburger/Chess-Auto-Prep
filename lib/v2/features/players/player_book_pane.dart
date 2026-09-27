import 'package:flutter/material.dart';

import '../../chess/book/book_check.dart';
import '../../ui/theme.dart';
import 'player_book.dart';

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
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Find this player’s replies your active book does not answer.',
              ),
              Wrap(
                spacing: Space.s,
                children: [
                  FilledButton(
                    onPressed: book.busy ? null : book.check,
                    child: Text(book.busy ? 'Checking…' : 'Check my book'),
                  ),
                  TextButton(
                    onPressed: onBooks,
                    child: const Text('Choose book'),
                  ),
                ],
              ),
              if (book.status != null) Text(book.status!),
              if (book.busy) const LinearProgressIndicator(),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: book.gaps.length,
            itemBuilder: (context, i) {
              final finding = book.gaps[i];
              final game = book.analysis.corpus!.games[finding.game];
              return ListTile(
                title: Text(
                  finding.gap.kind == Deviation.theirs
                      ? 'Unanswered reply · ${finding.gap.played}'
                      : 'Past the end of the book · ${finding.gap.played}',
                ),
                subtitle: Text('${game.title} · ${game.date}'),
                onTap: () => onOpen(finding),
              );
            },
          ),
        ),
      ],
    ),
  );
}
