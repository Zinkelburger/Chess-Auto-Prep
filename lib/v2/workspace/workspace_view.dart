import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../storage/settings_store.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'board_claim.dart';
import 'board_view.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_analysis.dart';
import 'engine_pane.dart';
import 'explorer.dart';
import 'explorer_pane.dart';
import 'fill_gaps.dart';
import 'fill_line.dart';
import 'game_counter.dart';
import 'game_fetcher.dart';
import 'gap_hunt.dart';
import 'move_note.dart';
import 'move_tree_view.dart';
import 'nav_row.dart';
import 'reading_header.dart';
import 'replies.dart';
import 'replies_pane.dart';
import 'workspace_tabs.dart';

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
    required this.session,
    required this.saver,
    required this.analysis,
    required this.replies,
    required this.gaps,
    required this.explorer,
    required this.games,
    required this.fill,
    required this.tabs,
    required this.editing,
    required this.settings,
    this.moveMenu,
    this.onExplorerGame,
    this.boardClaim,
    this.trainTab,
    this.treeTab,
    this.onBoardMove,
    this.onEngineMove,
    this.puzzle,
    this.header = true,
    this.gameCounter = true,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;
  final Replies replies;
  final GapHunt gaps;
  final Explorer explorer;
  final GameFetcher games;

  /// Asked to open a game the explorer lists, which is the shell's
  /// business: another mode shows it.
  final ValueChanged<ExplorerGame>? onExplorerGame;

  /// The run that writes proposed lines, for its one line on the card.
  final FillGaps fill;

  /// Which of the card's tabs are open and which is up. The shell owns it,
  /// as it owns [editing]: the keys and the Actions menu turn it too.
  final PaneTabs<WorkspaceTab> tabs;

  /// For what the board draws: the coordinates, today.
  final SettingsStore settings;

  /// Whether the edit strip is open. The shell owns it: the Actions menu
  /// and Ctrl+E turn it, and the strip's Done turns it off.
  final ValueNotifier<bool> editing;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  /// A position another owner is showing on the board instead of the
  /// document's, while it holds one: a lesson.
  final ValueListenable<BoardClaim?>? boardClaim;

  /// The Train tab's body, which is a feature's: the shell hands it in.
  final WidgetBuilder? trainTab;

  /// The Tree tab's body, which the shell builds: it opens other files.
  final WidgetBuilder? treeTab;

  /// Where a move made on the board goes when not into the document: a
  /// puzzle judges it. Null plays it into the document.
  final ValueChanged<String>? onBoardMove;

  /// Where the moves of a clicked engine line go when not into the
  /// document: the Tree tab's free board. Null plays them into it.
  final ValueChanged<String>? onEngineMove;

  /// What the Puzzle tab shows, which is the Tactics mode's.
  final Widget? puzzle;

  /// Whether the card is headed with the game's players and the board has
  /// the file's game counter under it. Tactics has neither: the puzzle says
  /// whose game it was and the list is how to get to another.
  final bool header;
  final bool gameCounter;

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
      valueListenable: boardClaim ?? const _NoClaim(),
      builder: (context, claim, _) => claim == null
          ? _BoardAndCounter(
              session: session,
              settings: settings,
              onMove: onBoardMove ?? session.playMove,
              counter: gameCounter,
            )
          : _ClaimedBoard(claim: claim, settings: settings),
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
          if (header)
            ReadingHeader(session: session)
          else
            const SizedBox(height: Space.s),
          // While part of the game is hidden — a puzzle's answer — the
          // engine would read it out and the arrows would walk into it, so
          // neither is on the card until it is found or shown.
          _UnlessHidden(
            session: session,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: readingCardInset - Space.s,
              ),
              child: EnginePane(
                session: session,
                analysis: analysis,
                onMove: onEngineMove,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: readingCardInset),
            child: FillLine(fill: fill),
          ),
          Expanded(
            child: _Tabbed(
              session: session,
              replies: replies,
              gaps: gaps,
              explorer: explorer,
              games: games,
              tabs: tabs,
              moveMenu: moveMenu,
              onExplorerGame: onExplorerGame,
              trainTab: trainTab,
              treeTab: treeTab,
              puzzle: puzzle,
            ),
          ),
          EditStrip(session: session, saver: saver, editing: editing),
          _UnlessHidden(
            session: session,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1),
                NavRow(session: session),
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
    required this.session,
    required this.replies,
    required this.gaps,
    required this.explorer,
    required this.games,
    required this.tabs,
    required this.moveMenu,
    required this.onExplorerGame,
    required this.trainTab,
    required this.treeTab,
    required this.puzzle,
  });

  final DocumentSession session;
  final Replies replies;
  final GapHunt gaps;
  final Explorer explorer;
  final GameFetcher games;
  final PaneTabs<WorkspaceTab> tabs;
  final MoveMenu? moveMenu;
  final ValueChanged<ExplorerGame>? onExplorerGame;
  final WidgetBuilder? trainTab;
  final WidgetBuilder? treeTab;
  final Widget? puzzle;

  Widget _body(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.moves => MoveTreeView(session: session, moveMenu: moveMenu),
    WorkspaceTab.train => trainTab?.call(context) ?? const SizedBox.shrink(),
    WorkspaceTab.replies => RepliesPane(
      session: session,
      replies: replies,
      gaps: gaps,
    ),
    WorkspaceTab.explorer => ExplorerPane(
      session: session,
      explorer: explorer,
      games: games,
      onOpenGame: onExplorerGame,
    ),
    WorkspaceTab.tree => treeTab?.call(context) ?? const SizedBox.shrink(),
    WorkspaceTab.puzzle => puzzle ?? const SizedBox.shrink(),
  };

  Widget? _trailing(WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.replies => _NextGap(gaps: gaps),
    WorkspaceTab.moves ||
    WorkspaceTab.train ||
    WorkspaceTab.tree ||
    WorkspaceTab.explorer ||
    WorkspaceTab.puzzle => null,
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
