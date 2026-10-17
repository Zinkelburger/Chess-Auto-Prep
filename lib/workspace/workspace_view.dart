import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'action_layout.dart';
import 'action_panes.dart';
import 'audit_pane.dart';
import 'explorer.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'board_claim.dart';
import 'board_and_card.dart';
import 'board_column.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_pane.dart';
import 'explorer_pane.dart';
import 'game_review_pane.dart';
import 'move_field.dart';
import 'move_tree_view.dart';
import 'nav_row.dart';
import 'reading_header.dart';
import 'replies_pane.dart';
import 'search_pane.dart';
import 'workspace.dart';
import 'workspace_hooks.dart';
import 'workspace_tabs.dart';
import 'training_analysis_pane.dart';
import '../ui/app_keys.dart';

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
          ? BoardAndCounter(
              session: workspace.session,
              noteEditable: hooks.builder,
              editing: hooks.noteEditing ? editing : null,
              quiet: hooks.quietBoard,
              engineInBoard: !hooks.trainingTools,
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
            studyTools: hooks.onAnnotate != null,
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
    WorkspaceTab.analysis when hooks.trainingTools => TrainingAnalysisPane(
      workspace: workspace,
      onMove: hooks.onEngineMove,
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
      onShowPositions: hooks.onShowPositions,
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

  Widget _moves() {
    final solitaire = workspace.solitaire;
    Widget reader() => MoveTreeView(
      session: workspace.session,
      moveMenu: (path) => [
        if (hooks.onAnnotate != null)
          MenuItemButton(
            onPressed: () {
              workspace.session.cursor.goTo(path);
              hooks.onAnnotate!();
            },
            child: const Text('Comment this move'),
          ),
        ...?hooks.moveMenu?.call(path),
      ],
      heading: hooks.header ? _heading() : null,
      preview: solitaire?.active == true && solitaire?.record != null
          ? (tree: solitaire!.record!, onRead: solitaire.inspect)
          : null,
    );
    Widget annotatedReader() => hooks.onAnnotate == null
        ? reader()
        : ListenableBuilder(
            listenable: workspace.session,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (workspace.session.chapter != null &&
                    workspace.session.shownTo == null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Tooltip(
                      message: AppKey.edit.tip('Annotate the selected move'),
                      child: TextButton(
                        onPressed: hooks.onAnnotate,
                        child: const Text('Annotate'),
                      ),
                    ),
                  ),
                Expanded(child: reader()),
              ],
            ),
          );
    return solitaire == null
        ? annotatedReader()
        : ListenableBuilder(
            listenable: solitaire,
            builder: (context, _) =>
                solitaire.active ? reader() : annotatedReader(),
          );
  }

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
