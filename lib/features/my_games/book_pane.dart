import 'package:flutter/material.dart';

import '../../chess/book/book_check.dart';
import '../../ui/theme.dart';
import '../../workspace/board_book_pane.dart' show showBookMoment;
import '../../workspace/book_verdict_view.dart';
import '../../workspace/document_session.dart';
import 'book_words.dart';
import 'game_book.dart';
import '../../ui/move_notation.dart';

/// The Book tab: what the user's book says about the game on the board.
/// The verdict, the move that left the book beside what the book plays
/// there, and how each of those goes on; the way back to the moment and
/// the way into the file that holds the line.
class BookPane extends StatefulWidget {
  const BookPane({
    super.key,
    required this.book,
    required this.session,
    required this.onReadBook,
  });

  final GameBook book;
  final DocumentSession session;

  /// Opens a place in a repertoire file in the builder, which is the
  /// shell's business.
  final ValueChanged<BookPlace> onReadBook;

  @override
  State<BookPane> createState() => _BookPaneState();
}

class _BookPaneState extends State<BookPane> {
  @override
  void initState() {
    super.initState();
    widget.book.watch();
  }

  @override
  void didUpdateWidget(BookPane old) {
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

  void _toMoment(CheckedGame checked) =>
      showBookMoment(widget.session, checked.verdict, checked.game);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.book, widget.session]),
      builder: (context, _) {
        final session = widget.session;
        final checked = widget.book.find(session.source, session.game);
        if (checked == null) {
          return BookSentence(switch (widget.book) {
            GameBook(problem: _?) => 'Could not compare your games.',
            GameBook(state: BookReading()) =>
              'Reading your games and repertoires…',
            _ =>
              'Open one of your games from the list to compare it with '
                  'your book.',
          });
        }
        return ListView(
          padding: const EdgeInsets.all(Space.m),
          children: [
            _Headline(checked: checked),
            const SizedBox(height: Space.m),
            _body(checked),
          ],
        );
      },
    );
  }

  Widget _body(CheckedGame checked) => BookVerdictDetail(
    verdict: checked.verdict,
    game: checked.game,
    onReadBook: widget.onReadBook,
    onMoment: () => _toMoment(checked),
  );
}

/// The verdict in full ink, and whose game it was under it.
class _Headline extends StatelessWidget {
  const _Headline({required this.checked});

  final CheckedGame checked;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(displaySan(context, verdictLine(checked)), style: text.titleSmall),
        Text(gameLine(checked.game), style: text.bodySmall),
      ],
    );
  }
}
