import 'package:flutter/material.dart';

import '../chess/book/book_check.dart';
import '../chess/book/played_game.dart';
import '../chess/pgn/game_tree.dart' show NodePath;
import '../ui/move_notation.dart';
import '../ui/theme.dart';
import 'board_book.dart';
import 'book_verdict_view.dart';
import 'document_session.dart';

/// The My books tab: what the book in use says about the game on the board,
/// read from the side the board is seen from — flip the board to check the
/// other side's book.
class BoardBookPane extends StatefulWidget {
  const BoardBookPane({
    super.key,
    required this.book,
    required this.session,
    required this.onReadBook,
    this.bookChip,
  });

  final BoardBook book;
  final DocumentSession session;

  /// Opens a place in a repertoire file in the builder.
  final ValueChanged<BookPlace> onReadBook;

  /// The book in use and the way to change it.
  final Widget? bookChip;

  @override
  State<BoardBookPane> createState() => _BoardBookPaneState();
}

class _BoardBookPaneState extends State<BoardBookPane> {
  @override
  void initState() {
    super.initState();
    widget.book.watch();
  }

  @override
  void didUpdateWidget(BoardBookPane old) {
    super.didUpdateWidget(old);
    if (old.book != widget.book) {
      old.book.unwatch();
      widget.book.watch();
    }
  }

  @override
  void dispose() {
    widget.book.unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.book,
    builder: (context, _) {
      final text = Theme.of(context).textTheme;
      return ListView(
        padding: const EdgeInsets.all(Space.m),
        children: [
          ?widget.bookChip,
          switch (widget.book.state) {
            BoardBookIdle() => const BookSentence(
              'Open a game to check it against your books.',
              inset: false,
            ),
            BoardBookReading() => const BookSentence(
              'Reading your repertoires…',
              inset: false,
            ),
            BoardBookFailed() => const BookSentence(
              'Could not read your repertoires.',
              inset: false,
            ),
            BoardBookNotSet() => const BookSentence(
              'No book set. Pick the book to compare games with.',
              inset: false,
            ),
            BoardBookChecked(:final game, :final verdict, :final book) =>
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    displaySan(context, bookVerdictLine(verdict, game)),
                    style: text.titleSmall,
                  ),
                  Text(
                    'As ${sideName(game.side)} · $book',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: Space.m),
                  BookVerdictDetail(
                    verdict: verdict,
                    game: game,
                    onReadBook: widget.onReadBook,
                    onMoment: () =>
                        showBookMoment(widget.session, verdict, game),
                  ),
                ],
              ),
          },
        ],
      );
    },
  );
}

/// Puts the board on the move [verdict] is about in the game on it.
void showBookMoment(
  DocumentSession session,
  BookVerdict verdict,
  PlayedGame game,
) => session.goTo(NodePath.of(List.filled(bookMoment(verdict, game), 0)));

/// The line under a game's heading when it left the book: the verdict and
/// `Show my line`, which opens My books at the moment. Nothing when the
/// game stayed in book, entered none or no book is in use: it is only said
/// when it is news.
class BookDeviationLine extends StatefulWidget {
  const BookDeviationLine({
    super.key,
    required this.book,
    required this.onShowLine,
  });

  final BoardBook book;
  final VoidCallback onShowLine;

  @override
  State<BookDeviationLine> createState() => _BookDeviationLineState();
}

class _BookDeviationLineState extends State<BookDeviationLine> {
  @override
  void initState() {
    super.initState();
    widget.book.watch();
  }

  @override
  void didUpdateWidget(BookDeviationLine old) {
    super.didUpdateWidget(old);
    if (old.book != widget.book) {
      old.book.unwatch();
      widget.book.watch();
    }
  }

  @override
  void dispose() {
    widget.book.unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.book,
    builder: (context, _) {
      final state = widget.book.state;
      if (state is! BoardBookChecked || state.verdict is! LeftBook) {
        return const SizedBox.shrink();
      }
      final theme = Theme.of(context);
      final left = state.verdict as LeftBook;
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.s),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Space.s,
          children: [
            Text(
              displaySan(
                context,
                '${bookVerdictLine(left, state.game)} · ${left.place.file.name}',
              ),
              style: theme.textTheme.bodySmall,
            ),
            TextButton(
              onPressed: widget.onShowLine,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              child: const Text('Show my line'),
            ),
          ],
        ),
      );
    },
  );
}
