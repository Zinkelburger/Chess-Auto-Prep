import 'package:flutter/material.dart';

import '../../chess/book/book_check.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/document_session.dart';
import 'book_words.dart';
import 'game_book.dart';

/// The two ways the column lists what the book says: game by game, or
/// grouped by where the games left it, most often first.
enum _View { games, openings }

/// The My games column: the user's accounts at the top, then their saved
/// games, each with what their book says about it, or the places the games
/// keep leaving the book. Clicking either opens the game at that moment.
///
/// The panel keeps which view is up; everything else is the book's,
/// including the search, since ↑ and ↓ walk the games it finds.
class MyGamesPanel extends StatefulWidget {
  const MyGamesPanel({
    super.key,
    required this.book,
    required this.session,
    required this.accounts,
    required this.bookChip,
    required this.onOpen,
    this.trailing,
  });

  /// The book the games are read against, to switch or edit.
  final Widget bookChip;

  final GameBook book;

  /// Which game is on the board, so its row is marked.
  final DocumentSession session;

  /// The usernames and the button that gets the games, which the host
  /// builds: the same block the Tactics column has.
  final Widget accounts;

  /// Opens a game at its [CheckedGame.moment].
  final ValueChanged<CheckedGame> onOpen;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<MyGamesPanel> createState() => _MyGamesPanelState();
}

class _MyGamesPanelState extends State<MyGamesPanel> {
  final _search = TextEditingController();
  _View _view = _View.games;

  @override
  void initState() {
    super.initState();
    // A column built again, after another mode, shows the search the list
    // is still narrowed by.
    _search.text = widget.book.query;
    widget.book.watch();
  }

  @override
  void didUpdateWidget(MyGamesPanel old) {
    super.didUpdateWidget(old);
    if (old.book != widget.book) {
      old.book.unwatch();
      _search.text = widget.book.query;
      widget.book.watch();
    }
  }

  @override
  void dispose() {
    widget.book.unwatch();
    _search.dispose();
    super.dispose();
  }

  void _show(_View view) {
    if (mounted) setState(() => _view = view);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.book, widget.session]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(trailing: widget.trailing),
          widget.accounts,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s),
            child: Align(
              alignment: Alignment.centerLeft,
              child: widget.bookChip,
            ),
          ),
          Expanded(
            child: switch (widget.book.state) {
              BookReading() => const _Message(
                'Reading your games and repertoires…',
              ),
              BookNoAccounts() => const SizedBox.shrink(),
              BookNotSet() => const _Message(
                'No book set. Pick the book to compare your games with.',
              ),
              BookChecked(:final games) when games.isEmpty => const _Message(
                'No games saved yet. Get games above to download them.',
              ),
              final BookChecked checked => _checked(checked),
            },
          ),
        ],
      ),
    );
  }

  Widget _checked(BookChecked checked) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
        child: SegmentedButton<_View>(
          segments: const [
            ButtonSegment(value: _View.games, label: Text('Games')),
            ButtonSegment(value: _View.openings, label: Text('Openings')),
          ],
          selected: {_view},
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: Space.xs),
            ),
          ),
          onSelectionChanged: (picked) => _show(picked.single),
        ),
      ),
      Expanded(
        child: switch (_view) {
          _View.games => _games(checked),
          _View.openings => _Openings(checked: checked, onOpen: widget.onOpen),
        },
      ),
    ],
  );

  bool _isOpen(CheckedGame checked) =>
      widget.session.source == checked.file &&
      widget.session.game == checked.game.index;

  Widget _games(BookChecked checked) {
    final all = checked.games.length;
    final query = widget.book.query;
    final shown = widget.book.shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
          child: SearchField(
            controller: _search,
            hint: 'Search by opponent, date or move',
            onChanged: widget.book.search,
          ),
        ),
        _CountLine(
          words: query.isEmpty
              ? '$all games, newest first'
              : '${shown.length} of $all games',
        ),
        Expanded(
          child: shown.isEmpty
              ? _Message('Nothing matches "$query".')
              : ListView.builder(
                  itemCount: shown.length,
                  itemExtent: puzzleRowHeight,
                  itemBuilder: (context, at) => _GameRow(
                    checked: shown[at],
                    open: _isOpen(shown[at]),
                    onOpen: () => widget.onOpen(shown[at]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The panel's name and the host's toggle in the corner.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.trailing});

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'My games',
              style: Theme.of(context).textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _CountLine extends StatelessWidget {
  const _CountLine({required this.words});

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.m, Space.xs),
    child: Text(
      words,
      style: Theme.of(context).textTheme.labelSmall,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// One game: who it was against, how it went and when on the first line,
/// cut short in a narrow column; what the book says on the second.
class _GameRow extends StatelessWidget {
  const _GameRow({
    required this.checked,
    required this.open,
    required this.onOpen,
  });

  final CheckedGame checked;

  /// This is the game on the board.
  final bool open;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final game = checked.game;
    return Material(
      color: open ? theme.colorScheme.surfaceContainerHighest : null,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                gameLine(game),
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              _Tag(checked: checked),
            ],
          ),
        ),
      ),
    );
  }
}

/// The move a verdict is about in full ink, then what happened there in
/// muted words: `6.f3 left book`.
class _Tag extends StatelessWidget {
  const _Tag({required this.checked});

  final CheckedGame checked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (move, words) = verdictTag(checked);
    return Text.rich(
      TextSpan(
        children: [
          if (move.isNotEmpty)
            TextSpan(
              text: '$move ',
              style: monoText.copyWith(color: theme.colorScheme.onSurface),
            ),
          TextSpan(text: words, style: theme.textTheme.labelSmall),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The places the games left the book, in three groups — the user's own
/// moves, the opponents' moves the book has no answer for, and where the
/// book ran out — each most often first.
class _Openings extends StatelessWidget {
  const _Openings({required this.checked, required this.onOpen});

  final BookChecked checked;
  final ValueChanged<CheckedGame> onOpen;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (final kind in Deviation.values) {
      final ways = checked.waysOf(kind);
      if (ways.isEmpty) continue;
      items.add(_Heading('${deviationHeading(kind)} (${ways.length})'));
      for (final way in ways) {
        items.add(_WayRow(way: way, onOpen: () => onOpen(way.games.first)));
      }
    }
    if (items.isEmpty) {
      return const _Message('None of these games left your book.');
    }
    return ListView(children: items);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.xs),
    child: Text(words, style: Theme.of(context).textTheme.labelSmall),
  );
}

/// One way games left the book: the move and how many games, then what the
/// book has there and in which file. Opens the newest of those games.
class _WayRow extends StatelessWidget {
  const _WayRow({required this.way, required this.onOpen});

  final SameWay way;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = way.games.length;
    final (move, book) = wayLines(way.verdict, way.games.first.game);
    return SizedBox(
      height: puzzleRowHeight,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      move,
                      style: monoText.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  Text(
                    count == 1 ? '1 game' : '$count games',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
              Text(
                book,
                style: theme.textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}
