import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/app_action.dart';
import '../ui/app_icons.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'action_layout.dart';
import 'action_panes.dart';
import 'analysis/engine_pane.dart';
import 'analysis/training_analysis_pane.dart';
import 'board/board_and_card.dart';
import 'board/board_claim.dart';
import 'board/board_column.dart';
import 'board/move_field.dart';
import 'board/nav_row.dart';
import 'book/replies_pane.dart';
import 'document/document_session.dart';
import 'explorer/explorer.dart';
import 'explorer/explorer_pane.dart';
import 'reading/edit_strip.dart';
import 'reading/edit_switch.dart';
import 'reading/move_tree_view.dart';
import 'reading/notes_pane.dart';
import 'reading/reading_header.dart';
import 'review/audit_pane.dart';
import 'review/game_review_pane.dart';
import 'search/search_pane.dart';
import 'workspace.dart';
import 'workspace_hooks.dart';
import 'workspace_tabs.dart';

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
  /// turns it, and the strip's Done turns it off.
  final ValueNotifier<bool> editing;

  /// The words and focus of the move field under the board. The shell owns
  /// them: a lesson types into it.
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
    return _NoteRoom(
      child: ListenableBuilder(
        listenable: layout ?? tabs,
        builder: (context, _) => BoardAndCard(
          board: (_) => _BoardSide(view: this),
          card: (_) => _ReadingCard(view: this),
          layout: layout,
        ),
      ),
    );
  }

  /// Whether the Notes tab is up in a pane. It is where the note is
  /// written then, so the card under the board and the edit strip show
  /// theirs to read and keep no second box for the same words.
  bool get _notesUp {
    final layout = this.layout;
    return layout == null
        ? tabs.selected == WorkspaceTab.notes
        : layout.visible.any(
            (i) =>
                !layout.isEmpty(i) &&
                layout.pane(i).selected == WorkspaceTab.notes,
          );
  }
}

/// Whether the move's note fits under the board, told by the board column
/// after each layout and read by the edit strip, which writes the note
/// itself when it does not.
class _NoteRoom extends StatefulWidget {
  const _NoteRoom({required this.child});

  final Widget child;

  static ValueNotifier<bool> of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_NoteRoomScope>()!.shown;

  @override
  State<_NoteRoom> createState() => _NoteRoomState();
}

class _NoteRoomState extends State<_NoteRoom> {
  final _shown = ValueNotifier(true);

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _NoteRoomScope(shown: _shown, child: widget.child);
}

class _NoteRoomScope extends InheritedWidget {
  const _NoteRoomScope({required this.shown, required super.child});

  final ValueNotifier<bool> shown;

  @override
  bool updateShouldNotify(_NoteRoomScope oldWidget) =>
      shown != oldWidget.shown;
}

/// The board, or whatever has claimed it, with the view's margin.
class _BoardSide extends StatelessWidget {
  const _BoardSide({required this.view});

  final WorkspaceView view;

  @override
  Widget build(BuildContext context) {
    final WorkspaceView(:workspace, :hooks, :editing, :moves) = view;
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: ValueListenableBuilder<BoardClaim?>(
        valueListenable: hooks.boardClaim ?? const _NoClaim(),
        builder: (context, claim, _) => claim == null
            ? BoardAndCounter(
                session: workspace.session,
                noteEditable: hooks.builder && !view._notesUp,
                reserveNote: hooks.builder || hooks.noteEditing,
                editing: hooks.noteEditing && !view._notesUp ? editing : null,
                quiet: hooks.quietBoard,
                engineInBoard: !hooks.trainingTools,
                noteShown: _NoteRoom.of(context),
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
            : ClaimedBoard(
                claim: claim,
                settings: workspace.settings,
                moves: moves,
              ),
      ),
    );
  }
}

/// The reading column is a card: darker than the window around it, its
/// corners rounded, the board's margin kept on three sides and the
/// divider's on the fourth. The words sit in from its edge.
class _ReadingCard extends StatelessWidget {
  const _ReadingCard({required this.view});

  final WorkspaceView view;

  @override
  Widget build(BuildContext context) {
    final WorkspaceView(:workspace, :tabs, :layout, :editing, :hooks) = view;
    return Padding(
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
            // The note is written under the board only where it fits
            // there; in a short window the strip writes it.
            ValueListenableBuilder<bool>(
              valueListenable: _NoteRoom.of(context),
              builder: (context, noteShown, _) => EditStrip(
                session: workspace.session,
                saver: workspace.saver,
                editing: editing,
                onSave: hooks.onSaveHeld,
                commentInNote:
                    (hooks.noteEditing && noteShown) || view._notesUp,
                studyTools: hooks.studyTools,
                done: !hooks.editSwitch,
              ),
            ),
            // While part of the game is hidden the arrows would walk into it.
            _UnlessHidden(
              session: workspace.session,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1),
                  NavRow(
                    session: workspace.session,
                    book: layout?.book,
                    leading: hooks.editSwitch
                        ? EditSwitch(
                            session: workspace.session,
                            editing: editing,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The moves, the opponent's replies, the explorer or the search, under
/// the strip that says which. The tabs are the window's: the shell owns
/// them, the keys walk them and the Actions menu opens and closes them, so
/// this only draws what is up. A new thing the card can show is one more
/// arm of [_TabBody]; a control it owns sits in its own body.
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

  @override
  Widget build(BuildContext context) {
    final layout = this.layout;
    return layout != null
        ? ActionPanes(
            layout: layout,
            actions: hooks.paneActions,
            body: (context, index, tab) => _VisibleBody(
              workspace: workspace,
              hooks: hooks,
              tab: tab,
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
                Expanded(
                  child: _VisibleBody(
                    workspace: workspace,
                    hooks: hooks,
                    tab: tabs.selected,
                  ),
                ),
              ],
            ),
          );
  }
}

/// [tab]'s body, or a word in its place while a lesson hides the answers.
class _VisibleBody extends StatelessWidget {
  const _VisibleBody({
    required this.workspace,
    required this.hooks,
    required this.tab,
    this.explorer,
    this.book,
  });

  final Workspace workspace;
  final WorkspaceHooks hooks;
  final WorkspaceTab tab;
  final Explorer? explorer;
  final ValueNotifier<bool>? book;

  /// The tabs that show the document's moves or what follows them.
  static bool _tellsAnswers(WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.moves ||
    WorkspaceTab.notes ||
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

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<BoardClaim?>(
    valueListenable: hooks.lesson ?? const _NoClaim(),
    builder: (context, lesson, _) => lesson != null && _tellsAnswers(tab)
        ? Padding(
            padding: const EdgeInsets.all(readingCardInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hidden while training',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (hooks.onStudyLesson != null) ...[
                  const SizedBox(height: Space.s),
                  OutlinedButton(
                    onPressed: hooks.onStudyLesson,
                    child: const Text('Reveal help and study'),
                  ),
                  const SizedBox(height: Space.s),
                  const Text('Your lesson stays ready to resume.'),
                ],
              ],
            ),
          )
        : _TabBody(
            workspace: workspace,
            hooks: hooks,
            tab: tab,
            explorer: explorer,
            book: book,
          ),
  );
}

/// What [tab] shows.
class _TabBody extends StatelessWidget {
  const _TabBody({
    required this.workspace,
    required this.hooks,
    required this.tab,
    this.explorer,
    this.book,
  });

  final Workspace workspace;
  final WorkspaceHooks hooks;
  final WorkspaceTab tab;
  final Explorer? explorer;
  final ValueNotifier<bool>? book;

  @override
  Widget build(BuildContext context) {
    final book = this.book;
    final moves = _MovesTab(workspace: workspace, hooks: hooks);
    final explorerTab = _ExplorerTab(
      workspace: workspace,
      hooks: hooks,
      explorer: explorer,
    );
    final supplied = _Supplied(hooks: hooks, tab: tab);
    return switch (tab) {
      WorkspaceTab.moves when book != null => ValueListenableBuilder<bool>(
        valueListenable: book,
        builder: (context, open, _) => open
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 2, child: moves),
                  const Divider(height: 1),
                  Expanded(flex: 3, child: explorerTab),
                ],
              )
            : moves,
      ),
      WorkspaceTab.analysis when hooks.trainingTools => TrainingAnalysisPane(
        workspace: workspace,
        onMove: hooks.onEngineMove,
      ),
      WorkspaceTab.moves || WorkspaceTab.analysis => moves,
      WorkspaceTab.notes => NotesPane(session: workspace.session),
      WorkspaceTab.review =>
        workspace.review == null
            ? const SizedBox.shrink()
            : GameReviewPane(review: workspace.review!),
      WorkspaceTab.train => supplied,
      WorkspaceTab.replies => RepliesPane(
        session: workspace.session,
        replies: workspace.replies,
        gaps: workspace.gaps,
      ),
      WorkspaceTab.explorer => explorerTab,
      WorkspaceTab.search => SearchPane(
        fill: workspace.fill,
        session: workspace.session,
        settings: workspace.settings,
        onOpenChapter: hooks.onOpenChapter,
        onShowPositions: hooks.onShowPositions,
        onTogglePositions: hooks.onTogglePositions,
      ),
      WorkspaceTab.audit =>
        workspace.audit == null
            ? const SizedBox.shrink()
            : AuditPane(audit: workspace.audit!, session: workspace.session),
      WorkspaceTab.puzzle || WorkspaceTab.source => supplied,
      WorkspaceTab.book || WorkspaceTab.solitaire => supplied,
      WorkspaceTab.filter => supplied,
      WorkspaceTab.player || WorkspaceTab.playerBook => supplied,
    };
  }
}

/// What the mode on screen puts in [tab]; nothing if it has no such tab.
class _Supplied extends StatelessWidget {
  const _Supplied({required this.hooks, required this.tab});

  final WorkspaceHooks hooks;
  final WorkspaceTab tab;

  @override
  Widget build(BuildContext context) =>
      hooks.tabBody?.call(context, tab) ?? const SizedBox.shrink();
}

/// The moves, headed as a book heads a game.
class _MovesTab extends StatelessWidget {
  const _MovesTab({required this.workspace, required this.hooks});

  final Workspace workspace;
  final WorkspaceHooks hooks;

  @override
  Widget build(BuildContext context) {
    final solitaire = workspace.solitaire;
    // A click on a move while a note is being typed goes there at once: in
    // the note's tap region the press does not take its focus first, which
    // would commit the note and redraw the list under the pointer. Leaving
    // the move commits the note to the move it was typed for.
    Widget reader() => TextFieldTapRegion(
      child: MoveTreeView(
        session: workspace.session,
        moveMenu: (path) => [
          if (hooks.onAnnotate != null)
            AppAction('Comment this move', () {
              workspace.session.cursor.goTo(path);
              hooks.onAnnotate!();
            }, icon: AppIcons.comment),
          ...?hooks.moveMenu?.call(path),
        ],
        heading: hooks.header
            ? _Heading(workspace: workspace, hooks: hooks)
            : null,
        preview: solitaire?.active == true && solitaire?.record != null
            ? (tree: solitaire!.record!, onRead: solitaire.inspect)
            : null,
      ),
    );
    return solitaire == null
        ? reader()
        : ListenableBuilder(
            listenable: solitaire,
            builder: (context, _) => reader(),
          );
  }
}

/// At a puzzle the table would tick the answer, or list it as the only
/// move with This file, so it goes while the answer is hidden, as the
/// engine pane does.
class _ExplorerTab extends StatelessWidget {
  const _ExplorerTab({
    required this.workspace,
    required this.hooks,
    this.explorer,
  });

  final Workspace workspace;
  final WorkspaceHooks hooks;
  final Explorer? explorer;

  @override
  Widget build(BuildContext context) => _UnlessHidden(
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
}

/// What is open and, under it, what the mode says about it.
class _Heading extends StatelessWidget {
  const _Heading({required this.workspace, required this.hooks});

  final Workspace workspace;
  final WorkspaceHooks hooks;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      ReadingHeader(session: workspace.session, openings: workspace.openings),
      ?hooks.underHeading,
    ],
  );
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
