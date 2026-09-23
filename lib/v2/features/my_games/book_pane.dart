import 'package:flutter/material.dart';

import '../../chess/book/book_check.dart';
import '../../chess/pgn/game_tree.dart' show NodePath;
import '../../chess/pgn/move_label.dart' show continuation;
import '../../ui/theme.dart';
import '../../workspace/document_session.dart';
import 'book_words.dart';
import 'game_book.dart';

/// Plies of a book line's continuation a row shows.
const bookLinePlies = 6;

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
      widget.session.goTo(NodePath.of(List.filled(checked.moment, 0)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.book, widget.session]),
      builder: (context, _) {
        final session = widget.session;
        final checked = widget.book.find(session.source, session.game);
        if (checked == null) {
          return _Sentence(
            widget.book.state is BookReading
                ? 'Reading your games and repertoires…'
                : 'Open one of your games from the list to compare it with '
                      'your book.',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(Space.m),
          children: [
            _Headline(checked: checked),
            const SizedBox(height: Space.m),
            ..._body(checked),
          ],
        );
      },
    );
  }

  List<Widget> _body(CheckedGame checked) => switch (checked.verdict) {
    NoBook() => [
      _Sentence(
        'You have no ${sideName(checked.game.side)} repertoire yet. Build '
        'one in the Repertoire builder and your games as '
        '${sideName(checked.game.side)} are compared with it.',
        inset: false,
      ),
    ],
    OtherOpening() => const [
      _Sentence(
        'This game left your books before a full move was played: another '
        'opening, not a mistake.',
        inset: false,
      ),
    ],
    InBookThroughout(:final place) => [
      _Sentence('Every move is in ${place.file.name}.', inset: false),
      _Actions(place: place, onReadBook: widget.onReadBook),
    ],
    final LeftBook left => [
      _Moves(left: left, onReadBook: widget.onReadBook),
      const SizedBox(height: Space.m),
      _Actions(
        place: left.place,
        onReadBook: widget.onReadBook,
        onMoment: () => _toMoment(checked),
      ),
    ],
  };
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
        Text(verdictLine(checked), style: text.titleSmall),
        Text(gameLine(checked.game), style: text.bodySmall),
      ],
    );
  }
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
              label,
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
            child: Text(goesOn, style: muted, overflow: TextOverflow.ellipsis),
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
            style: secondaryButtonStyle,
            onPressed: onMoment,
            icon: const Icon(Icons.my_location, size: IconSize.action),
            label: const Text('Show the move'),
          ),
        Tooltip(
          message: 'Open ${place.file.name} in the builder at this position',
          child: FilledButton.icon(
            style: secondaryButtonStyle,
            onPressed: () => onReadBook(place),
            icon: const Icon(Icons.menu_book, size: IconSize.action),
            label: const Text('Open in builder'),
          ),
        ),
      ],
    );
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence(this.words, {this.inset = true});

  final String words;

  /// Whether it sits in from the pane's edge on its own, or in a list that
  /// already does.
  final bool inset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(inset ? Space.m : 0),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );
}
