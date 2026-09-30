import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/book/book_check.dart';
import '../chess/book/played_game.dart';
import '../chess/pgn/move_label.dart' show continuation;
import '../ui/move_notation.dart';
import '../ui/theme.dart';

/// What the user's book says about one game, in words and as a panel: the
/// same wherever a game is checked — My games' list and Book tab, the
/// viewer's My books tab and the line under a game's heading — so a verdict
/// is never worded two ways.

/// Plies of a book line's continuation a row shows.
const bookLinePlies = 6;

/// `White`, `Black`.
String sideName(Side side) => side == Side.white ? 'White' : 'Black';

/// The one line said about [game]'s book.
String bookVerdictLine(BookVerdict verdict, PlayedGame game) =>
    switch (verdict) {
      NoBook() => 'Your book has no ${sideName(game.side)} chapters',
      OtherOpening() => 'Another opening',
      InBookThroughout() => 'In book to the end',
      LeftBook(kind: Deviation.mine, :final played, :final book) =>
        'You left book: $played (book ${book.first.label})',
      LeftBook(kind: Deviation.theirs, :final played) =>
        'Not in your book: $played',
      LeftBook(kind: Deviation.bookEnded, :final ply) =>
        'Book ended after ${game.moves[ply - 1].label}',
    };

/// How many of [game]'s moves to show for [verdict]: the move that left
/// the book, the last move of a book that ran out, the end of a game in
/// book throughout, else the start.
int bookMoment(BookVerdict verdict, PlayedGame game) => switch (verdict) {
  final LeftBook left => leftBookMoment(left),
  InBookThroughout() => game.moves.length,
  NoBook() || OtherOpening() => 0,
};

/// How many moves to show for a game that [left] the book: through the
/// move that left it, or through the last book move when the book ran out.
int leftBookMoment(LeftBook left) =>
    left.kind == Deviation.bookEnded ? left.ply : left.ply + 1;

/// The verdict in full, under the headline its host writes: the move that
/// left the book beside every move the book plays there, how each goes on
/// and in which file; the way back to the moment and into the book.
class BookVerdictDetail extends StatelessWidget {
  const BookVerdictDetail({
    super.key,
    required this.verdict,
    required this.game,
    required this.onReadBook,
    this.onMoment,
  });

  final BookVerdict verdict;
  final PlayedGame game;

  /// Opens a place in a repertoire file in the builder.
  final ValueChanged<BookPlace> onReadBook;

  /// Puts the board back on the moment the verdict is about.
  final VoidCallback? onMoment;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: switch (verdict) {
      NoBook() => [
        BookSentence(
          'Your book has no ${sideName(game.side)} chapters. Add some in '
          'Books and games as ${sideName(game.side)} are compared with them.',
          inset: false,
        ),
      ],
      OtherOpening() => const [
        BookSentence(
          'This game left your books before a full move was played: another '
          'opening, not a mistake.',
          inset: false,
        ),
      ],
      InBookThroughout(:final place) => [
        BookSentence('Every move is in ${place.file.name}.', inset: false),
        _Actions(place: place, onReadBook: onReadBook),
      ],
      final LeftBook left => [
        _Moves(left: left, onReadBook: onReadBook),
        const SizedBox(height: Space.m),
        _Actions(place: left.place, onReadBook: onReadBook, onMoment: onMoment),
      ],
    },
  );
}

/// The move the game played, then every move the book has there with its
/// lines, how the fullest file goes on and which file that is.
class _Moves extends StatelessWidget {
  const _Moves({required this.left, required this.onReadBook});

  final LeftBook left;
  final ValueChanged<BookPlace> onReadBook;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.labelSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Played', style: muted),
        _MoveRow(label: left.played),
        const SizedBox(height: Space.s),
        Text(
          left.book.isEmpty ? 'Your book ends before it' : 'Your book',
          style: muted,
        ),
        for (final move in left.book)
          _MoveRow(
            label: move.label,
            lines: move.lines,
            goesOn: continuation(move.at.node, plies: bookLinePlies),
            file: move.file.name,
            onFile: () => onReadBook(move.place),
          ),
      ],
    );
  }
}

/// One move: the move, and for a book move its lines, how it goes on and
/// the file, which opens there.
class _MoveRow extends StatelessWidget {
  const _MoveRow({
    required this.label,
    this.lines,
    this.goesOn = '',
    this.file,
    this.onFile,
  });

  final String label;
  final int? lines;
  final String goesOn;
  final String? file;
  final VoidCallback? onFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = monoText.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SizedBox(
      height: replyRowHeight,
      child: Row(
        children: [
          SizedBox(
            width: explorerMoveWidth,
            child: Text(
              displaySan(context, label),
              style: monoText.copyWith(color: theme.colorScheme.onSurface),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: treeLinesWidth,
            child: Text(switch (lines) {
              null => '',
              1 => '1 line',
              final n => '$n lines',
            }, style: theme.textTheme.labelSmall),
          ),
          Expanded(
            child: Text(
              displaySan(context, goesOn),
              style: muted,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (file case final file?)
            SizedBox(
              width: treeFilesWidth,
              child: Tooltip(
                message: 'Open $file here',
                child: InkWell(
                  onTap: onFile,
                  child: Text(
                    file,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Back to the moment in the game, and into the book where it left.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.place,
    required this.onReadBook,
    this.onMoment,
  });

  final BookPlace place;
  final ValueChanged<BookPlace> onReadBook;

  /// Puts the board back on the moment; null where there is none to show.
  final VoidCallback? onMoment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      children: [
        if (onMoment case final onMoment?)
          FilledButton.icon(
            onPressed: onMoment,
            icon: const Icon(Icons.my_location, size: IconSize.action),
            label: const Text('Show the move'),
          ),
        Tooltip(
          message: 'Open ${place.file.name} in the builder at this position',
          child: FilledButton.icon(
            onPressed: () => onReadBook(place),
            icon: const Icon(Icons.menu_book, size: IconSize.action),
            label: const Text('Open in builder'),
          ),
        ),
      ],
    );
  }
}

/// A sentence in a book pane: in from the pane's edge on its own, or flush
/// in a list that already is.
class BookSentence extends StatelessWidget {
  const BookSentence(this.words, {super.key, this.inset = true});

  final String words;
  final bool inset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(inset ? Space.m : 0),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );
}
