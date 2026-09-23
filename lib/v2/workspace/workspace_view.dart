import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../chess/fen.dart';
import '../storage/chapter_files.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'board_claim.dart';
import 'board_view.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_pane.dart';
import 'explorer.dart';
import 'explorer_pane.dart';
import 'game_counter.dart';
import 'move_field.dart';
import 'move_note.dart';
import 'move_tree_view.dart';
import 'reading_header.dart';
import 'replies_pane.dart';
import 'search_pane.dart';
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
    this.onOpenChapter,
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

  /// Opens a chapter in the builder: the draft a search's lines went to.
  final ValueChanged<ChapterRef>? onOpenChapter;

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

/// The board with the game counter, the engine's lines and the move's note
/// under it on the left; on the right the reading card, top to bottom in a
/// fixed order: the heading, the tab strip, the moves, the opponent's
/// replies, the explorer or the search, the edit strip while there is
/// editing or trouble, and the navigation row.
/// The card starts wider than the board. The keys that
/// walk the line and take an edit back are [WorkspaceKeys], above every
/// column that edits the document.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.workspace,
    required this.tabs,
    required this.editing,
    required this.moves,
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

  /// The words and focus of the move field under the board. The shell owns
  /// them: its `/` focuses the field and a lesson types into it.
  final MoveEntry moves;

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
              moves: moves,
              // While part of the game is hidden — a puzzle's answer — the
              // engine would read it out, so it is not shown until the
              // answer is found or shown.
              engine: _UnlessHidden(
                session: workspace.session,
                child: EnginePane(
                  session: workspace.session,
                  analysis: workspace.analysis,
                  onMove: hooks.onEngineMove,
                ),
              ),
            )
          : _ClaimedBoard(
              claim: claim,
              settings: workspace.settings,
              moves: moves,
            ),
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
          Expanded(
            child: _Tabbed(workspace: workspace, tabs: tabs, hooks: hooks),
          ),
          EditStrip(
            session: workspace.session,
            saver: workspace.saver,
            editing: editing,
          ),
          // While part of the game is hidden the arrows would walk into it.
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

/// The moves, the opponent's replies, the explorer or the search, under
/// the strip that says which. The tabs are the window's: the shell owns
/// them, the keys walk them and the Actions menu opens and closes them, so
/// this only draws what is up. A new thing the card can show is one more
/// arm of [_body]; a control it owns sits in its own body.
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
    WorkspaceTab.search => SearchPane(
      fill: workspace.fill,
      session: workspace.session,
      settings: workspace.settings,
      onOpenChapter: hooks.onOpenChapter,
    ),
    WorkspaceTab.puzzle => _supplied(context, tab),
    WorkspaceTab.book => _supplied(context, tab),
  };

  Widget _supplied(BuildContext context, WorkspaceTab tab) =>
      hooks.tabBody?.call(context, tab) ?? const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              readingCardInset - Space.m,
              Space.s,
              readingCardInset - Space.m,
              Space.xs,
            ),
            child: PaneTabStrip(tabs: tabs),
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

/// The room under the board the engine's lines and the row of the move
/// field and the counter take: the engine's switch row and one row per
/// line whether or not the engine is on, so the board keeps its size as it
/// is turned on and off. A line opened out scrolls in its room.
double _roomUnder(SettingsStore settings) =>
    navRowHeight +
    Space.s +
    engineBarHeight +
    settings.value.engineLines * engineRowHeight;

/// The largest square board that fits above the engine's lines and the
/// row with the move field and the counter, at the top, and the move's note
/// in what they leave below, when that is enough to read a few lines in.
class _BoardAndCounter extends StatelessWidget {
  const _BoardAndCounter({
    required this.session,
    required this.settings,
    required this.onMove,
    required this.counter,
    required this.moves,
    required this.engine,
  });

  final DocumentSession session;
  final SettingsStore settings;

  /// Where a move made on the board or typed into the field goes.
  final ValueChanged<String> onMove;

  /// Whether the game counter sits under the board.
  final bool counter;
  final MoveEntry moves;

  /// The engine's lines, under the counter.
  final Widget engine;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = _roomUnder(settings);
        final engineRoom = room - Space.s - navRowHeight;
        final side = min(constraints.maxWidth, constraints.maxHeight - room);
        final below = constraints.maxHeight - side - room - Space.s;
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
                  height: engineRoom,
                  child: SingleChildScrollView(child: engine),
                ),
                SizedBox(
                  height: navRowHeight,
                  child: Row(
                    children: [
                      ListenableBuilder(
                        listenable: session.anyChange,
                        builder: (context, _) => _Typed(
                          moves: moves,
                          fen: session.fen,
                          onMove: onMove,
                        ),
                      ),
                      Expanded(
                        child: counter
                            ? GameCounter(session: session)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
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

/// The board while another owner holds it: its position and the move
/// field alone, with the room the engine, the counter and the note would
/// take left empty, so the board and the field do not move as a lesson
/// starts and ends.
class _ClaimedBoard extends StatelessWidget {
  const _ClaimedBoard({
    required this.claim,
    required this.settings,
    required this.moves,
  });

  final BoardClaim claim;
  final SettingsStore settings;
  final MoveEntry moves;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = _roomUnder(settings);
        final side = min(constraints.maxWidth, constraints.maxHeight - room);
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListenableBuilder(
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
                SizedBox(height: room - navRowHeight),
                SizedBox(
                  height: navRowHeight,
                  child: _Typed(
                    moves: moves,
                    fen: claim.fen,
                    onMove: claim.onMove,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static void _still(String uci) {}
}

/// The move field at its width, in the row under the board.
class _Typed extends StatelessWidget {
  const _Typed({required this.moves, required this.fen, required this.onMove});

  final MoveEntry moves;
  final Fen fen;
  final ValueChanged<String>? onMove;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: moveFieldWidth,
    child: Center(
      child: MoveField(entry: moves, fen: fen, onMove: onMove),
    ),
  );
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
              _button(
                Icons.first_page,
                withKey('Start', 'Home'),
                open,
                session.toStart,
              ),
              _button(
                Icons.chevron_left,
                withKey('Back', '←'),
                open,
                session.back,
              ),
              _button(
                Icons.chevron_right,
                withKey('Forward', '→'),
                open,
                session.forward,
              ),
              _button(
                Icons.last_page,
                withKey('End', 'End'),
                open,
                session.toEnd,
              ),
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
