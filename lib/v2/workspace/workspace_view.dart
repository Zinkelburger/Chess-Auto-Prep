import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../storage/settings_store.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'board_claim.dart';
import 'board_view.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_pane.dart';
import 'explorer.dart';
import 'explorer_pane.dart';
import 'fill_gaps.dart';
import 'game_counter.dart';
import 'gap_hunt.dart';
import 'move_note.dart';
import 'move_tree_view.dart';
import 'prep_pane.dart';
import 'reading_header.dart';
import 'replies_pane.dart';
import 'workspace.dart';
import 'workspace_tabs.dart';

/// What the window around the workspace adds to it: the mode's own tabs
/// and right-click menu, where a move goes when it is not the document's,
/// and the ways out of the card into another mode. The default is a plain
/// document: every move into it, nothing of a mode's own.
final class WorkspaceHooks {
  const WorkspaceHooks({
    this.header = true,
    this.gameCounter = true,
    this.moveMenu,
    this.tabBody,
    this.boardClaim,
    this.onBoardMove,
    this.onEngineMove,
    this.onExplorerGame,
    this.onGenerate,
    this.onFound,
  });

  /// Asked to open a game the explorer lists, which is the shell's
  /// business: another mode shows it.
  final ValueChanged<ExplorerGame>? onExplorerGame;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  /// A position another owner is showing on the board instead of the
  /// document's, while it holds one: a lesson.
  final ValueListenable<BoardClaim?>? boardClaim;

  /// Opens the search dialog: the Prep tab's `Generate…`. Null leaves it
  /// off.
  final VoidCallback? onGenerate;

  /// Puts the found item at this index on the board: a Prep tab row.
  final ValueChanged<int>? onFound;

  /// Where a move made on the board goes when not into the document: a
  /// puzzle judges it. Null plays it into the document.
  final ValueChanged<String>? onBoardMove;

  /// Where the moves of a clicked engine line go when not into the
  /// document: the Tree tab's free board. Null plays them into it.
  final ValueChanged<String>? onEngineMove;

  /// Whether the card is headed with the game's players and the board has
  /// the file's game counter under it. Tactics has neither: the puzzle says
  /// whose game it was and the list is how to get to another.
  final bool header;
  final bool gameCounter;

  /// The body of a tab the workspace does not draw itself — Train, Tree,
  /// Puzzle, Book — which the mode on screen or the shell supplies. A tab it
  /// answers null for is empty.
  final Widget? Function(BuildContext context, WorkspaceTab tab)? tabBody;
}

/// The board with the game counter and the move's note under it on the
/// left; on the right the reading card, top to bottom in a fixed order: the
/// heading, the engine, the fill's line while there is a fill to speak of,
/// the tab strip, the moves, the opponent's replies or the explorer, the
/// edit strip while there is editing or trouble, and the navigation row.
/// The card starts wider than the board. The keys that
/// walk the line and take an edit back are [WorkspaceKeys], above every
/// column that edits the document.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.workspace,
    required this.tabs,
    required this.editing,
    this.hooks = const WorkspaceHooks(),
  });

  /// The document and every owner worked out from its cursor.
  final Workspace workspace;

  /// Which of the card's tabs are open and which is up. The shell owns it,
  /// as it owns [editing]: the keys and the Actions menu turn it too.
  final PaneTabs<WorkspaceTab> tabs;

  /// Whether the edit strip is open. The shell owns it: the Actions menu
  /// and Ctrl+E turn it, and the strip's Done turns it off.
  final ValueNotifier<bool> editing;

  /// What the mode on screen and the shell add.
  final WorkspaceHooks hooks;

  /// The board and the card beside it, with a divider the user can drag
  /// between them. The card starts the wider of the two: training, the
  /// replies and the explorer have more to say than a board needs room for.
  /// The sizes live in the split view's own state, so they survive a
  /// rebuild and are lost with the window. The board shrinks to what its
  /// side leaves it.
  @override
  Widget build(BuildContext context) {
    return _BoardAndCard(board: _board, card: _column);
  }

  Widget _board(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: ValueListenableBuilder<BoardClaim?>(
      valueListenable: hooks.boardClaim ?? const _NoClaim(),
      builder: (context, claim, _) => claim == null
          ? _BoardAndCounter(
              session: workspace.session,
              settings: workspace.settings,
              onMove: hooks.onBoardMove ?? workspace.session.playMove,
              counter: hooks.gameCounter,
            )
          : _ClaimedBoard(claim: claim, settings: workspace.settings),
    ),
  );

  /// The reading column is a card: darker than the window around it, its
  /// corners rounded, the board's margin kept on three sides and the
  /// divider's on the fourth. The words sit in from its edge.
  Widget _column(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, Space.l, Space.l, Space.l),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(readingCardRadius),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hooks.header)
            ReadingHeader(session: workspace.session)
          else
            const SizedBox(height: Space.s),
          // While part of the game is hidden — a puzzle's answer — the
          // engine would read it out and the arrows would walk into it, so
          // neither is on the card until it is found or shown.
          _UnlessHidden(
            session: workspace.session,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: readingCardInset - Space.s,
              ),
              child: EnginePane(
                session: workspace.session,
                analysis: workspace.analysis,
                onMove: hooks.onEngineMove,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: readingCardInset),
            child: FillLine(fill: workspace.fill),
          ),
          Expanded(
            child: _Tabbed(workspace: workspace, tabs: tabs, hooks: hooks),
          ),
          EditStrip(
            session: workspace.session,
            saver: workspace.saver,
            editing: editing,
          ),
          _UnlessHidden(
            session: workspace.session,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1),
                NavRow(session: workspace.session),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The board and the card side by side. The split view keeps its areas —
/// and so the sizes the user dragged them to — in this state for the life
/// of the window, while what fills them is built from the widget of the
/// moment: an area's own builder would keep the first mode's panes.
class _BoardAndCard extends StatefulWidget {
  const _BoardAndCard({required this.board, required this.card});

  final WidgetBuilder board;
  final WidgetBuilder card;

  @override
  State<_BoardAndCard> createState() => _BoardAndCardState();
}

class _BoardAndCardState extends State<_BoardAndCard> {
  final _split = MultiSplitViewController(
    areas: [
      Area(data: _Side.board, flex: boardShare, min: boardPaneMinWidth),
      Area(data: _Side.card, flex: cardShare, min: readingPaneMinWidth),
    ],
  );

  @override
  void dispose() {
    _split.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiSplitViewTheme(
    data: paneTheme(Theme.of(context).colorScheme),
    child: MultiSplitView(
      controller: _split,
      builder: (context, area) => area.data == _Side.board
          ? widget.board(context)
          : widget.card(context),
    ),
  );
}

enum _Side { board, card }

/// The moves, the opponent's replies or the explorer, under the strip that
/// says which. The tabs are the window's: the shell owns them, the keys
/// walk them and the Actions menu opens and closes them, so this only
/// draws what is up. A new thing the card can show is one more arm of
/// [_body], and one more of [_trailing] when it owns a control.
class _Tabbed extends StatelessWidget {
  const _Tabbed({
    required this.workspace,
    required this.tabs,
    required this.hooks,
  });

  final Workspace workspace;
  final PaneTabs<WorkspaceTab> tabs;
  final WorkspaceHooks hooks;

  Widget _body(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.moves => MoveTreeView(
      session: workspace.session,
      moveMenu: hooks.moveMenu,
    ),
    WorkspaceTab.train => _supplied(context, tab),
    WorkspaceTab.replies => RepliesPane(
      session: workspace.session,
      replies: workspace.replies,
      gaps: workspace.gaps,
    ),
    WorkspaceTab.explorer => ExplorerPane(
      session: workspace.session,
      explorer: workspace.explorer,
      games: workspace.games,
      onOpenGame: hooks.onExplorerGame,
    ),
    WorkspaceTab.tree => _supplied(context, tab),
    WorkspaceTab.prep => PrepPane(
      fill: workspace.fill,
      session: workspace.session,
      onGo: hooks.onFound ?? _nowhere,
    ),
    WorkspaceTab.puzzle => _supplied(context, tab),
    WorkspaceTab.book => _supplied(context, tab),
  };

  static void _nowhere(int index) {}

  Widget _supplied(BuildContext context, WorkspaceTab tab) =>
      hooks.tabBody?.call(context, tab) ?? const SizedBox.shrink();

  Widget? _trailing(WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.replies => _NextGap(gaps: workspace.gaps),
    WorkspaceTab.prep => _Generate(
      fill: workspace.fill,
      onGenerate: hooks.onGenerate,
    ),
    WorkspaceTab.moves ||
    WorkspaceTab.train ||
    WorkspaceTab.tree ||
    WorkspaceTab.explorer ||
    WorkspaceTab.puzzle ||
    WorkspaceTab.book => null,
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: readingCardInset - Space.m,
            ),
            child: PaneTabStrip(
              tabs: tabs,
              closeShortcut: 'Ctrl+W',
              trailing: _trailing(tabs.selected),
            ),
          ),
          Expanded(child: _body(context, tabs.selected)),
        ],
      ),
    );
  }
}

/// [child] while the whole game is on view, nothing while the session
/// hides part of it.
class _UnlessHidden extends StatelessWidget {
  const _UnlessHidden({required this.session, required this.child});

  final DocumentSession session;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) =>
        session.shownTo == null ? child : const SizedBox.shrink(),
  );
}

/// The one control the Replies tab owns: the way to the next unanswered
/// position. Off while there is no gap to go to.
class _NextGap extends StatelessWidget {
  const _NextGap({required this.gaps});

  final GapHunt gaps;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: gaps,
      builder: (context, _) {
        final found = gaps.walk?.gaps ?? const [];
        return TextButton.icon(
          onPressed: found.isEmpty ? null : gaps.nextGap,
          icon: const Icon(Icons.skip_next, size: IconSize.action),
          label: const Text('Next gap'),
        );
      },
    );
  }
}

/// The one control the Prep tab owns: the search dialog. Off while a
/// search runs or nothing on the board can be searched.
class _Generate extends StatelessWidget {
  const _Generate({required this.fill, required this.onGenerate});

  final FillGaps fill;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: fill,
      builder: (context, _) => Tooltip(
        message: 'Search from the board for lines and traps (Ctrl+G)',
        child: TextButton(
          onPressed: fill.canStart ? onGenerate : null,
          child: const Text('Generate…'),
        ),
      ),
    );
  }
}

/// The largest square board that fits above the counter, at the top, and
/// the move's note in what the board leaves below, when that is enough to
/// read a few lines in.
class _BoardAndCounter extends StatelessWidget {
  const _BoardAndCounter({
    required this.session,
    required this.settings,
    required this.onMove,
    required this.counter,
  });

  final DocumentSession session;
  final SettingsStore settings;
  final ValueChanged<String> onMove;

  /// Whether the game counter sits under the board.
  final bool counter;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = min(
          constraints.maxWidth,
          constraints.maxHeight - navRowHeight - Space.s,
        );
        final below = constraints.maxHeight - side - navRowHeight - 2 * Space.s;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([session.anyChange, settings]),
                  builder: (context, _) => BoardView(
                    fen: session.fen,
                    orientation: session.orientation,
                    lastMove: session.currentMove?.uci,
                    onMove: onMove,
                    coordinates: settings.value.boardCoordinates,
                  ),
                ),
                const SizedBox(height: Space.s),
                SizedBox(
                  height: navRowHeight,
                  child: counter ? GameCounter(session: session) : null,
                ),
                if (below >= moveNoteMinHeight) ...[
                  const SizedBox(height: Space.s),
                  SizedBox(
                    width: side,
                    height: below,
                    child: MoveNote(session: session),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The board while another owner holds it: its position alone, with the
/// room the counter and the note would take left empty, so the board does
/// not change size as a lesson starts and ends.
class _ClaimedBoard extends StatelessWidget {
  const _ClaimedBoard({required this.claim, required this.settings});

  final BoardClaim claim;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = min(
          constraints.maxWidth,
          constraints.maxHeight - navRowHeight - Space.s,
        );
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: ListenableBuilder(
              listenable: settings,
              builder: (context, _) => BoardView(
                fen: claim.fen,
                orientation: claim.orientation,
                lastMove: claim.lastMove,
                onMove: claim.onMove ?? _still,
                movable: claim.onMove != null,
                coordinates: settings.value.boardCoordinates,
              ),
            ),
          ),
        );
      },
    );
  }

  static void _still(String uci) {}
}

/// No claim, ever: the board of a workspace nothing can take over.
class _NoClaim implements ValueListenable<BoardClaim?> {
  const _NoClaim();

  @override
  BoardClaim? get value => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// The four buttons under the moves that walk the line: start, back,
/// forward, end. Each says its key, because each has one.
class NavRow extends StatelessWidget {
  const NavRow({super.key, required this.session});

  final DocumentSession session;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: navRowHeight,
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final open = session.chapter != null;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _button(Icons.first_page, 'Start (Home)', open, session.toStart),
              _button(Icons.chevron_left, 'Back (←)', open, session.back),
              _button(
                Icons.chevron_right,
                'Forward (→)',
                open,
                session.forward,
              ),
              _button(Icons.last_page, 'End (End)', open, session.toEnd),
            ],
          );
        },
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, bool on, VoidCallback run) =>
      IconButton(
        icon: Icon(icon, size: IconSize.action),
        tooltip: tooltip,
        onPressed: on ? run : null,
        visualDensity: VisualDensity.compact,
      );
}

/// The one line the reading card gives a fill: what it is doing, or what
/// it did, with the one control that applies — Cancel while it runs, a
/// cross to take the outcome off the card. Nothing while there is no fill.
class FillLine extends StatelessWidget {
  const FillLine({super.key, required this.fill});

  final FillGaps fill;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: fill,
      builder: (context, _) {
        final theme = Theme.of(context);
        final (words, colour) = _describe(fill.state, theme.colorScheme);
        if (words == null) return const SizedBox.shrink();
        return SizedBox(
          height: engineBarHeight,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  words,
                  style: theme.textTheme.bodySmall?.copyWith(color: colour),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (fill.state case final FillRunning run) ...[
                TextButton(
                  onPressed: run.stopping ? null : fill.finish,
                  child: const Text('Finish now'),
                ),
                TextButton(
                  onPressed: run.cancelling ? null : fill.cancel,
                  child: const Text('Cancel'),
                ),
              ] else
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: IconSize.menu),
                  onPressed: fill.dismiss,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// What the line says for [state], and its colour when it is not the usual
/// one; no words while there is no fill.
(String?, Color?) _describe(FillState state, ColorScheme scheme) =>
    switch (state) {
      FillIdle() => (null, null),
      FillRunning(
        :final nodes,
        :final depth,
        :final of,
        :final cancelling,
        :final finishing,
      ) =>
        (
          cancelling
              ? 'Cancelling…'
              : finishing
              ? 'Finishing at depth $depth · $nodes positions'
              : 'Searching · depth $depth/$of · $nodes positions',
          null,
        ),
      FillDone(:final name, :final lines, :final traps, :final folded) => (
        [
          if (name == null)
            'Found ${_count(lines, 'line')}'
          else
            'Proposed ${_count(lines, 'line')} in $name',
          if (folded != 0) '$folded folded in',
          _count(traps, 'trap'),
        ].join(' · '),
        null,
      ),
      FillFailed(:final reason) => (reason, scheme.error),
    };

String _count(int n, String thing) => n == 1 ? '1 $thing' : '$n ${thing}s';
