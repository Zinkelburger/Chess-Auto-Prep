import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chess/explorer_answer.dart';
import '../../chess/explorer_choice.dart';
import '../../chess/openings.dart';
import '../../ui/app_icons.dart';
import '../../ui/list_message.dart';
import '../../ui/listening_state.dart';
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import '../board/line_preview.dart';
import '../board/preview_target.dart';
import '../book/book_chip.dart';
import '../book/books.dart';
import '../book/repertoire_tree.dart';
import '../book/tree_pane.dart';
import '../document/document_session.dart';
import 'explorer.dart';
import 'explorer_filters.dart';
import 'explorer_rows.dart';
import 'game_fetcher.dart';
import 'opening_names.dart';

/// The Explorer tab of the reading card, lila's opening explorer: what a
/// database has seen played from the position on the board.
///
/// At the top the databases side by side, the chosen one pressed, and its
/// filters folded behind `Filters`. Under them the table,
/// one row per move, most played first: the move, how many games and what
/// share, and how they ended as a bar; a tick when the chapter plays the
/// move here; a totals row to close it. Then the games the database names,
/// which open in the viewer. Clicking a move plays it, and on a repertoire
/// chapter that writes it; resting the pointer on one floats the position
/// after it.
///
/// `Book` is the user's own active book instead of a database: the moves
/// its chapters play here ([TreePane]), with the book's name to switch it
/// and a way to edit the books.
class ExplorerPane extends StatefulWidget {
  const ExplorerPane({
    super.key,
    required this.session,
    required this.explorer,
    required this.games,
    required this.tree,
    required this.books,
    required this.openings,
    this.onOpenGame,
    this.onLogIn,
    this.onDownloadTwic,
    this.onOpenPlace,
    this.onEditBooks,
    this.fileBar,
  });

  /// Under the databases while `This file` is chosen: the mode's way of
  /// narrowing the file's games.
  final Widget? fileBar;

  /// The active book by position, for `Book`.
  final RepertoireTree tree;
  final Books books;

  /// Names the position on the board over the table.
  final OpeningNames openings;

  /// Asked to open the chapter a book move was found in, where it leads.
  final ValueChanged<TreePlace>? onOpenPlace;

  /// Asked to show the Books mode; null hides the pencil.
  final VoidCallback? onEditBooks;

  final DocumentSession session;
  final Explorer explorer;

  /// The game being fetched, whose row says so while the others wait.
  final GameFetcher games;

  /// Asked to open one of the listed games, which is the shell's business:
  /// the game becomes a file and the viewer shows it. Null when nothing
  /// can, and then the games are listed without a click.
  final ValueChanged<ExplorerGame>? onOpenGame;

  final Future<bool> Function(BuildContext)? onLogIn;
  final Future<bool> Function(BuildContext)? onDownloadTwic;

  @override
  State<ExplorerPane> createState() => _ExplorerPaneState();
}

class _ExplorerPaneState extends State<ExplorerPane>
    with ListeningState<ExplorerPane> {
  final _preview = HoverPreview<LinePreview>();

  @override
  Listenable listenableOf(ExplorerPane widget) => widget.explorer;

  /// A row that goes takes the pointer's exit with it, so the floated board
  /// goes whenever the explorer has something new to show: other rows, a
  /// sentence in their place, or a line above them.
  @override
  void changed() => _leave();

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  void _hover(ExplorerRow row, Offset anchor) {
    _preview.rest(
      () => LinePreview(fen: row.after, lastMove: row.uci, anchor: anchor),
    );
  }

  void _leave() {
    _preview.leave();
  }

  void _play(ExplorerRow row) {
    _leave();
    if (widget.explorer.canPlay(row)) widget.session.playMove(row.uci);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.explorer,
        widget.games,
        widget.session,
      ]),
      builder: (context, _) => LinePreviewOverlay(
        preview: _preview,
        orientation: widget.session.orientation,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExplorerSourceBar(
              explorer: widget.explorer,
              onDownload:
                  widget.onDownloadTwic != null &&
                      widget.explorer.recovery != ExplorerRecovery.download
                  ? () => unawaited(_downloadTwic())
                  : null,
              thisFile: widget.fileBar,
              book: widget.onEditBooks == null
                  ? null
                  : BookChip(books: widget.books, onEdit: widget.onEditBooks!),
            ),
            _OpeningName(session: widget.session, openings: widget.openings),
            Expanded(
              child: widget.explorer.choice.source == ExplorerSource.book
                  // The book's columns are fixed, and its file a link: a
                  // pane narrower than they need, such as the moves' half
                  // of the builder's card, scrolls them sideways.
                  ? LayoutBuilder(
                      builder: (context, room) => SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: math.max(actionPaneMinWidth, room.maxWidth),
                          height: room.maxHeight,
                          child: TreePane(
                            session: widget.session,
                            tree: widget.tree,
                            onOpen: widget.onOpenPlace,
                          ),
                        ),
                      ),
                    )
                  : _body(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final explorer = widget.explorer;
    return switch (explorer.state) {
      ExplorerIdle() => const _Sentence(
        'Open a chapter or a game to see what is played.',
      ),
      ExplorerAsking(:final source) => _Sentence('Asking ${source.title}…'),
      ExplorerReading(:final done, :final total) => _Sentence(
        total == 0
            ? 'Reading the games…'
            : 'Reading the games… $done of $total',
      ),
      ExplorerNothing(:final sentence) => _Sentence(sentence),
      ExplorerFailed(:final sentence) => _Sentence(
        sentence,
        retry: explorer.retry,
        logIn:
            explorer.recovery == ExplorerRecovery.login &&
                widget.onLogIn != null
            ? _logIn
            : null,
        offline: _offline(),
        download:
            explorer.recovery == ExplorerRecovery.download &&
                widget.onDownloadTwic != null
            ? _downloadTwic
            : null,
      ),
      ExplorerShown(:final rows, :final answer) => _table(rows, answer),
    };
  }

  Future<void> _logIn() async {
    final loggedIn = await widget.onLogIn!(context);
    if (!mounted || !loggedIn) return;
    await widget.explorer.retry();
  }

  /// Beside a login Lichess asks for: the master games on this machine,
  /// which need none.
  Future<void> Function()? _offline() {
    final explorer = widget.explorer;
    if (explorer.recovery != ExplorerRecovery.login ||
        explorer.choice.source == ExplorerSource.twic) {
      return null;
    }
    return () async =>
        explorer.choose(explorer.choice.copyWith(source: ExplorerSource.twic));
  }

  Future<void> _downloadTwic() async {
    final ready = await widget.onDownloadTwic!(context);
    if (!mounted || !ready) return;
    await widget.explorer.retry();
  }

  Widget _table(List<ExplorerRow> rows, ExplorerAnswer answer) {
    final explorer = widget.explorer;
    final fetching = widget.games.fetching;
    // Each row is made when it scrolls into view.
    final items = <WidgetBuilder>[
      if (explorer.notice case final notice?)
        (_) => _Sentence(
          notice,
          retry: explorer.retry,
          logIn:
              explorer.recovery == ExplorerRecovery.login &&
                  widget.onLogIn != null
              ? _logIn
              : null,
          offline: _offline(),
          download:
              explorer.recovery == ExplorerRecovery.download &&
                  widget.onDownloadTwic != null
              ? _downloadTwic
              : null,
        ),
      (_) => const _Header(),
      for (final row in rows)
        (_) => _MoveRow(
          key: ValueKey(row.uci),
          row: row,
          onHover: (anchor) => _hover(row, anchor),
          onLeave: _leave,
          onTap: () => _play(row),
        ),
      (_) => _Totals(answer: answer),
      if (answer.games.isNotEmpty) (_) => const Divider(height: 1),
      for (final game in answer.games)
        (_) => ExplorerGameRow(
          key: ValueKey(game.id),
          game: game,
          fetching: fetching == game.id,
          onTap: widget.onOpenGame == null || fetching != null
              ? null
              : () => widget.onOpenGame!(game),
        ),
    ];
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) => items[index](context),
    );
  }
}

/// A sentence where the table would be, with `Try again` when that is a
/// thing to do, and TWIC beside a Lichess login.
class _Sentence extends StatelessWidget {
  const _Sentence(
    this.words, {
    this.retry,
    this.logIn,
    this.offline,
    this.download,
  });

  final String words;
  final Future<void> Function()? retry;
  final Future<void> Function()? logIn;
  final Future<void> Function()? offline;
  final Future<void> Function()? download;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: ListMessage(words, inset: Space.m, action: _action()),
  );

  Widget? _action() {
    if (logIn case final login?) {
      return Wrap(
        children: [
          TextButton(
            onPressed: () => unawaited(login()),
            child: const Text('Log in to Lichess…'),
          ),
          if (offline case final twic?)
            Tooltip(
              message: 'Master games on this machine; no login needed',
              child: TextButton(
                onPressed: () => unawaited(twic()),
                child: const Text('Use TWIC'),
              ),
            ),
        ],
      );
    }
    if (download case final start?) {
      return TextButton.icon(
        onPressed: () => unawaited(start()),
        icon: const Icon(AppIcons.download, size: IconSize.action),
        label: const Text('Download TWIC…'),
      );
    }
    if (retry case final again?) {
      return OutlinedButton(
        onPressed: () => unawaited(again()),
        child: const Text('Try again'),
      );
    }
    return null;
  }
}

/// The column names over the rows, in the rows' own widths.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall;
    return SizedBox(
      height: explorerHeaderHeight,
      child: Row(
        children: [
          const SizedBox(width: Space.m),
          SizedBox(
            width: explorerMoveWidth,
            child: Text('Move', style: style),
          ),
          SizedBox(
            width: explorerGamesWidth,
            child: Text('Games', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: Space.m),
          _BarColumn(bar: Text('White / Draw / Black', style: style)),
        ],
      ),
    );
  }
}

class _MoveRow extends StatelessWidget {
  const _MoveRow({
    super.key,
    required this.row,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final ExplorerRow row;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: PreviewTarget(
        onHover: onHover,
        onLeave: onLeave,
        onTap: onTap,
        child: SizedBox(
          height: replyRowHeight,
          child: Row(
            children: [
              const SizedBox(width: Space.m),
              SizedBox(width: explorerMoveWidth, child: _move(context, scheme)),
              SizedBox(
                width: explorerGamesWidth,
                child: Text(
                  '${formatGameCount(row.games)} · ${row.share}',
                  textAlign: TextAlign.right,
                  style: monoText.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: Space.m),
              _BarColumn(
                bar: ResultBar(
                  white: row.white,
                  draws: row.draws,
                  black: row.black,
                ),
                tick: _tick(scheme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The move alone: every row would carry the same number.
  Widget _move(BuildContext context, ColorScheme scheme) => Text(
    displaySan(context, row.san),
    style: monoText.copyWith(color: scheme.onSurface),
    overflow: TextOverflow.ellipsis,
  );

  /// A tick for a move the chapter plays here; the room for one otherwise,
  /// so the bars line up.
  Widget? _tick(ColorScheme scheme) => row.inRepertoire
      ? Icon(AppIcons.tick, size: IconSize.menu, color: scheme.onSurfaceVariant)
      : null;
}

/// The `Σ` row: every game at the position, however it went on.
class _Totals extends StatelessWidget {
  const _Totals({required this.answer});

  final ExplorerAnswer answer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        answer.whiteTotal +
        answer.drawTotal +
        answer.blackTotal +
        answer.undecidedTotal;
    return SizedBox(
      height: replyRowHeight,
      child: Row(
        children: [
          const SizedBox(width: Space.m),
          SizedBox(
            width: explorerMoveWidth,
            child: Text(
              'Σ',
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          SizedBox(
            width: explorerGamesWidth,
            child: Text(
              formatGameCount(total),
              textAlign: TextAlign.right,
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: Space.m),
          _BarColumn(
            bar: ResultBar(
              white: answer.whiteTotal,
              draws: answer.drawTotal,
              black: answer.blackTotal,
            ),
          ),
        ],
      ),
    );
  }
}

/// The rest of a table row: the bar at its capped width, then the tick
/// or the room for one, so every row's bar starts and ends in one place.
class _BarColumn extends StatelessWidget {
  const _BarColumn({required this.bar, this.tick});

  final Widget bar;
  final Widget? tick;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Row(
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: explorerBarMaxWidth),
            child: bar,
          ),
        ),
        const SizedBox(width: Space.s),
        SizedBox(width: IconSize.menu, child: tick),
        const SizedBox(width: Space.m),
      ],
    ),
  );
}

/// The name of the opening the board is in, lila's line over its explorer
/// table, as the reading card heads a game ([openingLine]). One line
/// always, empty where nothing names it, so the table under it stays put as
/// the moves go in and out of the book.
class _OpeningName extends StatelessWidget {
  const _OpeningName({required this.session, required this.openings});

  final DocumentSession session;
  final OpeningNames openings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session.anyChange, openings]),
    builder: (context, _) {
      final chapter = session.chapter;
      return Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.m, 0),
        child: Text(
          chapter == null
              ? ''
              : openingLine(
                  openings.book,
                  chapter,
                  session.cursor.value,
                  answerHidden: session.shownTo != null,
                ),
          key: const ValueKey('explorer-opening'),
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    },
  );
}
