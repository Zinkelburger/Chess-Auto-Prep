import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import 'action_layout.dart';
import 'action_panes.dart';
import 'audit_pane.dart';
import 'explorer.dart';
import '../chess/fen.dart';
import '../storage/chapter_files.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/listening_state.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'board_claim.dart';
import 'board_and_card.dart';
import 'board_view.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_pane.dart';
import 'engine_analysis.dart';
import 'explorer_pane.dart';
import 'game_counter.dart';
import 'game_ordering.dart';
import 'game_review_pane.dart';
import 'move_field.dart';
import 'move_note.dart';
import 'move_shapes.dart';
import 'move_tree_view.dart';
import 'reading_header.dart';
import 'replies_pane.dart';
import 'repertoire_tree.dart' show TreePlace;
import 'search_pane.dart';
import 'workspace.dart';
import 'workspace_tabs.dart';
import '../ui/app_keys.dart';

/// What the window around the workspace adds to it: the mode's own tabs
/// and right-click menu, where a move goes when it is not the document's,
/// and the ways out of the card into another mode. The default is a plain
/// document: every move into it, nothing of a mode's own.
final class WorkspaceHooks {
  const WorkspaceHooks({
    this.header = true,
    this.builder = false,
    this.noteEditing = false,
    this.gameCounter = true,
    this.gameOrdering,
    this.moveMenu,
    this.tabBody,
    this.boardClaim,
    this.lesson,
    this.onBoardMove,
    this.onEngineMove,
    this.onExplorerGame,
    this.onExplorerLogin,
    this.onDownloadTwic,
    this.onOpenChapter,
    this.onOpenPlace,
    this.onEditBooks,
    this.onSaveHeld,
    this.quietBoard = false,
    this.paneActions,
    this.explorerFileBar,
    this.underHeading,
  });

  /// Under the heading: what the mode has to say about the game before it
  /// is read, such as where it left the user's book.
  final Widget? underHeading;

  /// Whether the board has only what is in use under it, as a book has a
  /// diagram and nothing else: the engine's row while the engine is on, the
  /// move field while it is typed in, the move's note when there is one or
  /// while it is edited. The viewer's.
  final bool quietBoard;

  /// Under the explorer's databases while `This file` is chosen: the
  /// mode's way of narrowing the file's games.
  final Widget? explorerFileBar;

  /// What the mode adds to every pane's `+` under its tabs.
  final List<AppAction> Function()? paneActions;

  /// What the edit strip's Save does with held edits, when not simply
  /// writing them to their file.
  final VoidCallback? onSaveHeld;

  /// Opens the chapter a move of the book was found in, where it leads.
  final ValueChanged<TreePlace>? onOpenPlace;

  /// Shows the Books mode, to edit the books.
  final VoidCallback? onEditBooks;

  /// Asked to open a game the explorer lists, which is the shell's
  /// business: another mode shows it.
  final void Function(ExplorerGame, ExplorerSource, int)? onExplorerGame;
  final Future<bool> Function(BuildContext)? onExplorerLogin;
  final Future<bool> Function(BuildContext)? onDownloadTwic;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  /// A position another owner is showing on the board instead of the
  /// document's, while it holds one: a lesson.
  final ValueListenable<BoardClaim?>? boardClaim;

  /// The lesson's hold on the board, while one runs: every tab but Train
  /// would read out the moves it asks for, so they wait until it ends.
  final ValueListenable<BoardClaim?>? lesson;

  /// Opens a chapter in the builder: the draft a search's lines went to.
  final ValueChanged<ChapterRef>? onOpenChapter;

  /// Where a move made on the board goes when not into the document: a
  /// puzzle judges it. Null plays it into the document.
  final ValueChanged<String>? onBoardMove;

  /// Where the moves of a clicked engine line go when not into the
  /// document: the explorer Book's free board. Null plays them into it.
  final ValueChanged<String>? onEngineMove;

  /// Whether the moves are headed with the game's players and the board has
  /// the file's game counter under it. Tactics has neither: the puzzle says
  /// whose game it was and the list is how to get to another.
  final bool header;
  final bool builder;
  final bool noteEditing;
  final bool gameCounter;
  final GameOrdering? gameOrdering;

  /// The body of a tab the workspace does not draw itself — Train,
  /// Puzzle, Book — which the mode on screen or the shell supplies. A tab it
  /// answers null for is empty.
  final Widget? Function(BuildContext context, WorkspaceTab tab)? tabBody;
}

/// The board with the game counter, the engine's lines and the move's note
/// under it on the left; on the right the reading card: the panes of tabs
/// — the moves, the opponent's replies, the explorer, the search — then
/// the edit strip while there is editing or trouble, and the navigation
/// row. The heading is the top of the moves and scrolls with them, as a
/// book heads a game.
/// The card starts wider than the board. The keys that
/// walk the line and take an edit back are [WorkspaceKeys], above every
/// column that edits the document.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.workspace,
    required this.tabs,
    this.layout,
    required this.editing,
    required this.moves,
    this.hooks = const WorkspaceHooks(),
  });

  /// The document and every owner worked out from its cursor.
  final Workspace workspace;

  /// Which of the card's tabs are open and which is up. The shell owns it,
  /// as it owns [editing]: the keys and the Actions menu turn it too.
  final PaneTabs<WorkspaceTab> tabs;
  final ActionLayout? layout;

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
    return BoardAndCard(board: _board, card: _column, layout: layout);
  }

  Widget _board(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: ValueListenableBuilder<BoardClaim?>(
      valueListenable: hooks.boardClaim ?? const _NoClaim(),
      builder: (context, claim, _) => claim == null
          ? _BoardAndCounter(
              session: workspace.session,
              noteEditable: hooks.builder,
              editing: hooks.noteEditing ? editing : null,
              quiet: hooks.quietBoard,
              settings: workspace.settings,
              analysis: workspace.analysis,
              onMove: hooks.onBoardMove ?? workspace.session.playMove,
              counter: hooks.gameCounter,
              ordering: hooks.gameOrdering,
              moves: moves,
              // While part of the game is hidden — a puzzle's answer — the
              // engine would read it out, so it is not shown until the
              // answer is found or shown.
              engine: (settingsOpen) => _UnlessHidden(
                session: workspace.session,
                child: EnginePane(
                  session: workspace.session,
                  analysis: workspace.analysis,
                  settings: workspace.settings,
                  settingsOpen: settingsOpen,
                  coresAvailable: workspace.coresAvailable,
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
          Expanded(
            child: _Tabbed(
              workspace: workspace,
              tabs: tabs,
              hooks: hooks,
              layout: layout,
            ),
          ),
          EditStrip(
            session: workspace.session,
            saver: workspace.saver,
            editing: editing,
            onSave: hooks.onSaveHeld,
            commentInNote: hooks.noteEditing,
          ),
          // While part of the game is hidden the arrows would walk into it.
          _UnlessHidden(
            session: workspace.session,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1),
                NavRow(session: workspace.session, book: layout?.book),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The moves, the opponent's replies, the explorer or the search, under
/// the strip that says which. The tabs are the window's: the shell owns
/// them, the keys walk them and the Actions menu opens and closes them, so
/// this only draws what is up. A new thing the card can show is one more
/// arm of [_body]; a control it owns sits in its own body.
class _Tabbed extends StatelessWidget {
  const _Tabbed({
    required this.workspace,
    required this.tabs,
    this.layout,
    required this.hooks,
  });

  final Workspace workspace;
  final PaneTabs<WorkspaceTab> tabs;
  final ActionLayout? layout;
  final WorkspaceHooks hooks;

  Widget _body(
    BuildContext context,
    WorkspaceTab tab, {
    Explorer? explorer,
    ValueNotifier<bool>? book,
  }) => switch (tab) {
    WorkspaceTab.moves when book != null => ValueListenableBuilder<bool>(
      valueListenable: book,
      builder: (context, open, _) => open
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: _moves()),
                const Divider(height: 1),
                Expanded(flex: 3, child: _explorer(explorer)),
              ],
            )
          : _moves(),
    ),
    WorkspaceTab.moves || WorkspaceTab.analysis => _moves(),
    WorkspaceTab.review =>
      workspace.review == null
          ? const SizedBox.shrink()
          : GameReviewPane(review: workspace.review!),
    WorkspaceTab.train => _supplied(context, tab),
    WorkspaceTab.replies => RepliesPane(
      session: workspace.session,
      replies: workspace.replies,
      gaps: workspace.gaps,
    ),
    WorkspaceTab.explorer => _explorer(explorer),
    WorkspaceTab.search => SearchPane(
      fill: workspace.fill,
      session: workspace.session,
      settings: workspace.settings,
      onOpenChapter: hooks.onOpenChapter,
    ),
    WorkspaceTab.audit =>
      workspace.audit == null
          ? const SizedBox.shrink()
          : AuditPane(audit: workspace.audit!, session: workspace.session),
    WorkspaceTab.puzzle || WorkspaceTab.source => _supplied(context, tab),
    WorkspaceTab.book || WorkspaceTab.solitaire => _supplied(context, tab),
    WorkspaceTab.filter => _supplied(context, tab),
    WorkspaceTab.player || WorkspaceTab.playerBook => _supplied(context, tab),
  };

  Widget _moves() => MoveTreeView(
    session: workspace.session,
    moveMenu: hooks.moveMenu,
    heading: hooks.header ? _heading() : null,
  );

  // At a puzzle the table would tick the answer, or list it as the only
  // move with This file, so it goes while the answer is hidden, as the
  // engine pane does.
  Widget _explorer(Explorer? explorer) => _UnlessHidden(
    session: workspace.session,
    child: LayoutBuilder(
      builder: (context, size) => SingleChildScrollView(
        child: SizedBox(
          height: max(searchPaneMinHeight, size.maxHeight),
          child: ExplorerPane(
            session: workspace.session,
            explorer: explorer ?? workspace.explorer,
            games: workspace.games,
            tree: workspace.tree,
            books: workspace.books,
            openings: workspace.openings,
            onOpenGame: hooks.onExplorerGame == null
                ? null
                : (game) {
                    final owner = explorer ?? workspace.explorer;
                    hooks.onExplorerGame!(game, owner.choice.source, owner.ply);
                  },
            onLogIn: hooks.onExplorerLogin,
            onDownloadTwic: hooks.onDownloadTwic,
            onOpenPlace: hooks.onOpenPlace,
            onEditBooks: hooks.onEditBooks,
            fileBar: hooks.explorerFileBar,
          ),
        ),
      ),
    ),
  );

  /// What is open and, under it, what the mode says about it.
  Widget _heading() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      ReadingHeader(session: workspace.session, openings: workspace.openings),
      ?hooks.underHeading,
    ],
  );

  /// The tabs that show the document's moves or what follows them.
  static bool _tellsAnswers(WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.moves ||
    WorkspaceTab.analysis ||
    WorkspaceTab.review ||
    WorkspaceTab.replies ||
    WorkspaceTab.explorer ||
    WorkspaceTab.search ||
    WorkspaceTab.audit ||
    WorkspaceTab.player ||
    WorkspaceTab.playerBook => true,
    WorkspaceTab.train ||
    WorkspaceTab.puzzle ||
    WorkspaceTab.source ||
    WorkspaceTab.book ||
    WorkspaceTab.filter ||
    WorkspaceTab.solitaire => false,
  };

  Widget _supplied(BuildContext context, WorkspaceTab tab) =>
      hooks.tabBody?.call(context, tab) ?? const SizedBox.shrink();

  Widget _visibleBody(
    BuildContext context,
    WorkspaceTab tab, {
    Explorer? explorer,
    ValueNotifier<bool>? book,
  }) => ValueListenableBuilder<BoardClaim?>(
    valueListenable: hooks.lesson ?? const _NoClaim(),
    builder: (context, lesson, _) => lesson != null && _tellsAnswers(tab)
        ? Padding(
            padding: const EdgeInsets.all(readingCardInset),
            child: Text(
              'Hidden while training',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        : _body(context, tab, explorer: explorer, book: book),
  );

  @override
  Widget build(BuildContext context) {
    final layout = this.layout;
    return layout != null
        ? ActionPanes(
            layout: layout,
            actions: hooks.paneActions,
            body: (context, index, tab) => _visibleBody(
              context,
              tab,
              explorer:
                  tab == WorkspaceTab.explorer || tab == WorkspaceTab.moves
                  ? layout.explorer(index)
                  : null,
              book: layout.book,
            ),
          )
        : ListenableBuilder(
            listenable: tabs,
            builder: (context, _) => Column(
              children: [
                PaneTabStrip(tabs: tabs, connected: true),
                const Divider(height: 1),
                Expanded(child: _visibleBody(context, tabs.selected)),
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

/// The largest square board that fits above the engine's lines and the
/// row with the move field and the counter, at the top, and the move's note
/// in what they leave below, when that is enough to read a few lines in.
class _BoardAndCounter extends StatefulWidget {
  const _BoardAndCounter({
    required this.session,
    required this.settings,
    required this.onMove,
    required this.counter,
    this.ordering,
    required this.moves,
    required this.engine,
    required this.analysis,
    this.noteEditable = false,
    this.editing,
    this.quiet = false,
  });

  final DocumentSession session;
  final SettingsStore settings;
  final EngineAnalysis analysis;
  final bool noteEditable;
  final ValueNotifier<bool>? editing;

  /// Whether the engine's row, the move field and an empty note stay away
  /// until they are used ([WorkspaceHooks.quietBoard]).
  final bool quiet;

  /// Where a move made on the board or typed into the field goes.
  final ValueChanged<String> onMove;

  /// Whether the game counter sits under the board.
  final bool counter;
  final GameOrdering? ordering;
  final MoveEntry moves;

  /// The engine's lines, under the counter, or its settings while the
  /// notifier it is given says so.
  final Widget Function(ValueNotifier<bool> settingsOpen) engine;

  @override
  State<_BoardAndCounter> createState() => _BoardAndCounterState();
}

class _BoardAndCounterState extends State<_BoardAndCounter>
    with ListeningState<_BoardAndCounter> {
  double _engineRoom = 0;

  /// Whether the engine shows its settings in place of its lines: here,
  /// because the room the pane is given depends on it.
  final _engineSettings = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _engineRoom = _room();
  }

  @override
  void dispose() {
    stopListening();
    _engineSettings.dispose();
    super.dispose();
  }

  /// The engine's room: none while part of the game is hidden, and none on
  /// a quiet board until the engine is on.
  double _room() =>
      widget.session.shownTo != null ||
          (widget.quiet && !widget.analysis.enabled)
      ? 0
      : enginePaneHeight(widget.analysis, settingsOpen: _engineSettings.value);

  @override
  Listenable listenableOf(_BoardAndCounter widget) =>
      Listenable.merge([widget.session, widget.analysis, _engineSettings]);

  @override
  void changed() {
    final room = _room();
    if (!mounted || room == _engineRoom) return;
    setState(() => _engineRoom = room);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final settings = widget.settings;
    final onMove = widget.onMove;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = navRowHeight + moveFeedbackHeight + Space.s + _engineRoom;
        final noteRoom = widget.editing != null || widget.noteEditable
            ? moveNoteMinHeight + Space.s
            : 0.0;
        final side = min(
          constraints.maxWidth,
          max(0.0, constraints.maxHeight - room - noteRoom),
        );
        final below = constraints.maxHeight - side - room - Space.s;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([
                    session.anyChange,
                    settings,
                    widget.analysis.threat,
                    ?widget.editing,
                  ]),
                  // A comment's line on the board is read, not played on.
                  builder: (context, _) {
                    final keeps = drawsIntoComment(
                      session,
                      editing: widget.editing?.value ?? false,
                    );
                    return BoardView(
                      fen: session.boardFen,
                      orientation: session.orientation,
                      lastMove: session.boardLastMove,
                      onMove: onMove,
                      movable: session.commentLine.value == null,
                      coordinates: settings.value.boardCoordinates,
                      shapes: shapesOnBoard(session),
                      threat: threatOnBoard(
                        session,
                        widget.analysis.threat.value,
                      ),
                      onDraw: keeps
                          ? (shape) => drawIntoComment(session, shape)
                          : null,
                      onClear: keeps ? () => clearCommentShapes(session) : null,
                    );
                  },
                ),
                const SizedBox(height: Space.s),
                SizedBox(
                  height: _engineRoom,
                  child: SingleChildScrollView(
                    child: widget.engine(_engineSettings),
                  ),
                ),
                _navigation(),
                MoveFeedback(entry: widget.moves),
                if (below >= moveNoteMinHeight) _note(side, below),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The move's note in the room left under the row, [side] wide.
  Widget _note(double side, double below) => Padding(
    padding: const EdgeInsets.only(top: Space.s),
    child: SizedBox(
      width: side,
      height: below,
      child: MoveNote(
        session: widget.session,
        editable: widget.noteEditable,
        editing: widget.editing,
        quiet: widget.quiet,
      ),
    ),
  );

  Widget _navigation() => SizedBox(
    height: navRowHeight,
    child: Row(
      children: [
        ListenableBuilder(
          listenable: widget.session.anyChange,
          builder: (context, _) => _Typed(
            moves: widget.moves,
            fen: widget.session.boardFen,
            onMove: widget.session.commentLine.value == null
                ? widget.onMove
                : null,
            whenUsed: widget.quiet,
          ),
        ),
        Expanded(
          child: widget.counter
              ? GameCounter(session: widget.session, ordering: widget.ordering)
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

/// The board while another owner holds it: its position and the move
/// field alone. No engine space is reserved while a lesson owns the board.
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
        const room = navRowHeight + moveFeedbackHeight + Space.s;
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
                const SizedBox(height: Space.s),
                SizedBox(
                  height: navRowHeight,
                  child: _Typed(
                    moves: moves,
                    fen: claim.fen,
                    onMove: claim.onMove,
                  ),
                ),
                MoveFeedback(entry: moves),
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
  const _Typed({
    required this.moves,
    required this.fen,
    required this.onMove,
    this.whenUsed = false,
  });

  final MoveEntry moves;
  final Fen fen;
  final ValueChanged<String>? onMove;

  /// Whether the field is seen only while it has the keys or words in it.
  final bool whenUsed;

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      width: moveFieldWidth,
      child: Center(
        child: MoveField(entry: moves, fen: fen, onMove: onMove),
      ),
    );
    return whenUsed ? _WhenUsed(moves: moves, child: field) : field;
  }
}

/// The move field seen only while it has the keys or words in it. It keeps
/// its place and stays in the tree either way, so `/` finds it and nothing
/// beside it moves when it comes.
class _WhenUsed extends StatefulWidget {
  const _WhenUsed({required this.moves, required this.child});

  final MoveEntry moves;
  final Widget child;

  @override
  State<_WhenUsed> createState() => _WhenUsedState();
}

class _WhenUsedState extends State<_WhenUsed> with ListeningState<_WhenUsed> {
  bool _used = false;

  @override
  void initState() {
    super.initState();
    _used = _usedNow;
  }

  bool get _usedNow =>
      widget.moves.focus.hasFocus || widget.moves.words.text.isNotEmpty;

  @override
  Listenable listenableOf(_WhenUsed widget) =>
      Listenable.merge([widget.moves.focus, widget.moves.words]);

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  /// The field under this clears its own words while it is being built, on
  /// a new position; that is heard here, above it, so the change is shown
  /// once the frame is done.
  @override
  void changed() {
    if (!mounted || _usedNow == _used) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => changed());
      return;
    }
    setState(() => _used = _usedNow);
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_used,
    child: Opacity(opacity: _used ? 1 : 0, child: widget.child),
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
  const NavRow({super.key, required this.session, this.book});

  final DocumentSession session;

  /// Whether the opening book shows under the moves; its button leads the
  /// row, as Lichess's does, where the layout offers it.
  final ValueNotifier<bool>? book;

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
              if (book case final book?)
                ValueListenableBuilder<bool>(
                  valueListenable: book,
                  builder: (context, open, _) => IconButton(
                    icon: Icon(
                      open ? Icons.menu_book : Icons.menu_book_outlined,
                      size: IconSize.action,
                    ),
                    tooltip: open
                        ? 'Hide the opening book'
                        : 'Show the opening book under the moves',
                    isSelected: open,
                    onPressed: () => book.value = !open,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              _button(
                Icons.first_page,
                AppKey.start.tip('Start'),
                open,
                session.toStart,
              ),
              _button(
                Icons.chevron_left,
                AppKey.back.tip('Back'),
                open,
                session.back,
              ),
              _button(
                Icons.chevron_right,
                AppKey.forward.tip('Forward'),
                open,
                session.forward,
              ),
              _button(
                Icons.last_page,
                AppKey.end.tip('End'),
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
