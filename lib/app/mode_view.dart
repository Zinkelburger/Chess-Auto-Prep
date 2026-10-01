import '../features/tournaments/tournament_run.dart';
import 'tournament_view.dart';
import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../features/books/books_screen.dart';
import '../features/bughouse/bughouse_screen.dart';
import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../chess/explorer_choice.dart';
import '../features/pgn_viewer/filter_pane.dart';
import '../features/pgn_viewer/pgn_viewer_panel.dart';
import '../features/pgn_viewer/player_side_choice.dart';
import '../features/study/study_panel.dart';
import '../storage/chapter_files.dart';
import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/name_dialog.dart';
import '../ui/pane_tabs.dart';
import '../workspace/board_book.dart';
import '../workspace/board_book_pane.dart';
import '../workspace/book_chip.dart';
import '../workspace/repertoire_shelf.dart' show BookFileRef;
import '../workspace/chapter_commands.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_actions.dart';
import '../workspace/document_session.dart';
import '../workspace/explorer.dart';
import '../workspace/game_ordering.dart';
import '../workspace/move_tree_view.dart' show MoveMenu;
import '../workspace/solitaire.dart';
import '../workspace/solitaire_pane.dart';
import '../workspace/study_drafts.dart';
import '../workspace/workspace.dart';
import '../workspace/action_layout.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'database_view.dart';
import '../features/databases/database_library.dart';
import 'player_wiring.dart';
import 'player_views.dart';
import 'training_views.dart';
import 'window_input.dart';
import 'workspace_requests.dart';
import '../ui/app_keys.dart';

/// What the window's own dialogs do, which the shell runs: they need its
/// context. The Actions menu only points at them.
typedef ShellDialogs = ({
  VoidCallback saveCopy,
  VoidCallback saveHeld,
  VoidCallback exportPgn,
  VoidCallback search,
  VoidCallback accounts,
  VoidCallback newBook,
});

/// What the Actions menu is built from besides the mode: whether the edit
/// strip is open, the analysis board's entries (built only when a mode
/// offers them, since they read the shell's context) and the dialogs.
typedef ModeMenu = ({
  ValueNotifier<bool> editing,
  List<AppAction> Function() board,
  ShellDialogs dialogs,
});

/// One mode as the window shows it: its list on the left, the tabs of its
/// reading card, its Actions menu, and what it adds to the workspace.
///
/// The shell asks the mode on screen rather than asking which mode is on
/// screen, so a mode's behaviour is in one class and a new mode is a new
/// subclass, not a new arm in every `switch` of the window. Each keeps its
/// own tabs for the life of the window, so what the user opened in one mode
/// is still open when they come back to it.
abstract base class ModeView {
  /// [explorer] is the mode's own, when its Explorer tab starts on a
  /// database of its own instead of the one the settings remember.
  ///
  /// [opensBeside] is for a mode whose first pane reads well at half the
  /// card's height: a tab picked while it is the only pane opens under it.
  ModeView(
    this.workspace,
    PaneTabs<WorkspaceTab> tabs, {
    Explorer? explorer,
    bool opensBeside = false,
  }) : _explorer = explorer,
       layout = ActionLayout(
         tabs,
         explorer ?? workspace.explorer,
         opensBeside: opensBeside,
       );

  final Workspace workspace;
  final Explorer? _explorer;

  /// The reading card's tabs in this mode: which are open and which is up.
  final ActionLayout layout;
  PaneTabs<WorkspaceTab> get tabs => layout.tabs;

  /// Brings [tab] up where it is open, else opens it as the layout opens a
  /// picked tab.
  void show(WorkspaceTab tab) => layout.reveal(tab);

  /// The left column, with [toggle] — the `«` that hides it — in its corner.
  Widget list(Widget toggle);

  /// Everything the Actions menu offers in this mode now.
  List<AppAction> actions(ModeMenu menu);

  /// What the entries' enabled states read, heard only while the menu is
  /// open.
  Listenable get changes;

  /// Whether the moves are headed with the game's players.
  bool get header => true;

  /// Whether the board has the file's game counter under it.
  bool get gameCounter => true;
  GameOrdering? get gameOrdering => null;

  /// Whether the Train tab offers to read a line in the builder: from
  /// anywhere but the builder itself.
  bool get offersBuilder => true;

  /// Whether the Actions menu offers the game on a new analysis tab. The
  /// viewer does not: moves played there already stay off the file.
  bool get offersNewAnalysis => true;

  /// What a right-click on a move offers.
  MoveMenu? get moveMenu => null;

  /// Under the heading: what the mode says about the game before it is
  /// read; null for nothing.
  Widget? get underHeading => null;

  /// Whether the board has only what is in use under it.
  bool get quietBoard => false;

  /// Under the explorer's databases while `This file` is chosen.
  Widget? get explorerFileBar => null;

  /// What every pane's `+` offers under its tabs: what the mode keeps out
  /// of sight until it is asked for.
  List<AppAction> paneActions(ValueNotifier<bool> editing) => const [];

  /// The body of a tab only this mode has, or null.
  Widget? tab(BuildContext context, WorkspaceTab tab) => null;

  /// ↓ (1) / ↑ (−1) when the mode walks a list of its own; answers whether
  /// it took the key.
  bool walk(int by) => false;

  /// Space, when no puzzle is up: the viewer plays the game forward.
  void space() {}

  /// Esc, once the workspace has nothing left to leave; whether the mode
  /// left anything. Tactics ends its sitting.
  bool leave() => false;

  /// Called when this mode comes on screen in place of another, whoever
  /// switched to it.
  void entered() {}

  /// Called when another mode comes on screen instead of this one.
  void left() {}

  /// The whole of the window under the top bar, for a mode that is a
  /// screen of its own rather than a list beside the workspace; null for
  /// the rest. The screen binds [windowKeys] beside its own.
  Widget? screen(Map<ShortcutActivator, VoidCallback> windowKeys) => null;

  void dispose() {
    layout.dispose();
    _explorer?.dispose();
  }

  /// What can be done to the document on the board, in every mode that
  /// shows one as a document.
  List<AppAction> documentEntries(ModeMenu menu) => documentActions(
    session: workspace.session,
    analysis: workspace.analysis,
    editing: menu.editing,
    onSaveCopy: menu.dialogs.saveCopy,
    onSaveHeld: menu.dialogs.saveHeld,
  );
}

/// The three modes whose list opens a document: the builder, the viewer and
/// Study. They share the Actions menu and differ in the list and in the one
/// file entry.
abstract base class _DocumentModeView extends ModeView {
  _DocumentModeView(
    super.workspace,
    super.tabs,
    this.requests, {
    super.explorer,
    super.opensBeside,
  });

  final WorkspaceRequests requests;

  /// Pasting a repertoire in the builder, closing the file elsewhere.
  AppAction get fileEntry;

  @override
  Listenable get changes => Listenable.merge([
    workspace.session,
    workspace.saver,
    workspace.analysis,
    workspace.gaps,
    workspace.fill,
  ]);

  @override
  List<AppAction> actions(ModeMenu menu) => [
    AppAction(
      'Open PGN file…',
      () => unawaited(requests.openPgnFile()),
      shortcut: AppKey.openFile.label,
      group: 'File',
    ),
    fileEntry,
    if (this is _LibraryView) ..._repertoire(menu.dialogs),
    ...documentEntries(menu),
    ...menu.board(),
    ...tabActions(tabs, layout: layout),
  ];

  /// The chapter as a repertoire — its gaps, its side and the fill — or,
  /// on the analysis board, the search from it.
  List<AppAction> _repertoire(ShellDialogs dialogs) {
    final session = workspace.session;
    return [
      AppAction(
        'Expectimax from here',
        workspace.fill.canStart ? dialogs.search : null,
        shortcut: AppKey.search.label,
        group: 'Repertoire',
      ),
      AppAction(
        'Train this chapter',
        session.chapter == null ? null : () => show(WorkspaceTab.train),
        group: 'Repertoire',
      ),
      AppAction(
        'Next gap',
        workspace.gaps.canNextGap ? workspace.gaps.nextGap : null,
        group: 'Repertoire',
      ),
      if (workspace.audit case final audit?)
        AppAction(
          'Audit this chapter',
          audit.canStart
              ? () {
                  show(WorkspaceTab.audit);
                  unawaited(audit.start());
                }
              : null,
          group: 'Repertoire',
        ),
      if (session.chapter case final chapter? when chapter.game == null)
        AppAction(
          chapter.side == Side.white ? 'Play as Black' : 'Play as White',
          () => setSide(session, chapter.side.opposite),
          group: 'Repertoire',
        ),
    ];
  }
}

/// The two modes with the user's repertoires on the left: the builder and
/// the trainer. A file opened or pasted in either becomes a repertoire.
abstract base class _LibraryView extends _DocumentModeView {
  _LibraryView(super.workspace, super.tabs, super.requests, this._modes);

  final DocumentModes _modes;

  @override
  Widget list(Widget toggle) => ListenableBuilder(
    listenable: workspace.session,
    builder: (context, _) => LibraryPanel(
      library: _modes.library,
      selected: workspace.session.source,
      onOpen: (ref) => unawaited(requests.open(ref)),
      trailing: toggle,
    ),
  );

  @override
  AppAction get fileEntry => AppAction(
    'Paste PGN',
    () => unawaited(requests.pasteRepertoire()),
    // On the analysis board Ctrl+V pastes onto the board instead.
    shortcut: workspace.session.isScratch ? null : 'Ctrl+V',
    group: 'File',
  );
}

/// The Repertoire builder: the user's repertoires on the left.
final class RepertoiresView extends _LibraryView {
  RepertoiresView(
    Workspace workspace,
    WorkspaceRequests requests,
    DocumentModes modes,
  ) : super(workspace, newWorkspaceTabs(), requests, modes) {
    layout.startBuilding();
  }

  @override
  bool get offersBuilder => false;
}

/// The Repertoire trainer: the same repertoires on the left, and the Train
/// tab first on the card and always there. It is the builder's Train tab
/// with the building put away, for someone who came to drill.
final class TrainerView extends _LibraryView {
  TrainerView(
    Workspace workspace,
    WorkspaceRequests requests,
    DocumentModes modes,
  ) : super(workspace, trainerTabs(), requests, modes);

  /// Coming here is coming to train, whichever tab was left up.
  @override
  void entered() => show(WorkspaceTab.train);
}

/// The files the PGN Viewer has open or has had open.
final class ViewerView extends _DocumentModeView {
  ViewerView(Workspace workspace, WorkspaceRequests requests, this._modes)
    : super(
        workspace,
        viewerTabs(),
        requests,
        // What is played in the file being read comes first here; the
        // databases are a click away.
        explorer: workspace.explorer.independent(
          starting: ExplorerSource.thisFile,
        ),
        // The moves stay in view while a tool is used under them.
        opensBeside: true,
      );

  final DocumentModes _modes;

  Solitaire? get _solitaire => workspace.solitaire;

  @override
  Listenable get changes => Listenable.merge([
    super.changes,
    _modes.viewer,
    _modes.autoplay,
    ?workspace.review,
    ?_solitaire,
  ]);

  @override
  void space() {
    if (_solitaire?.active == true) return;
    _modes.autoplay.toggle();
  }

  /// Shows the Game review tab and starts the engine on the game, or stops
  /// the review that is running.
  void analyze() {
    final review = workspace.review;
    if (review == null) return;
    if (review.running) return review.stop();
    show(WorkspaceTab.review);
    unawaited(review.start());
  }

  /// Shows the Solitaire tab with its setup, or ends the session.
  void solitaire() {
    final solitaire = _solitaire;
    if (solitaire == null) return;
    if (solitaire.active) return solitaire.stop();
    _modes.autoplay.stop();
    solitaire.offer();
    show(WorkspaceTab.solitaire);
  }

  /// My books, on the move where the game left the book.
  void _showMyLine() {
    show(WorkspaceTab.book);
    if (workspace.boardBook?.state case BoardBookChecked(
      :final verdict,
      :final game,
    )) {
      showBookMoment(workspace.session, verdict, game);
    }
  }

  @override
  Widget? get underHeading => switch (workspace.boardBook) {
    final book? => BookDeviationLine(book: book, onShowLine: _showMyLine),
    null => null,
  };

  @override
  bool get quietBoard => true;

  /// Editing and the engine, which a file read as a book has no control
  /// on screen for: here with their keys, so they can be found.
  @override
  List<AppAction> paneActions(ValueNotifier<bool> editing) => [
    for (final action in documentActions(
      session: workspace.session,
      analysis: workspace.analysis,
      editing: editing,
      onSaveCopy: () {},
    ))
      if (action.shortcut == AppKey.edit.label ||
          action.shortcut == AppKey.engine.label)
        action,
  ];

  @override
  Widget? get explorerFileBar =>
      PlayerSideChoice(viewer: _modes.viewer, filter: _modes.filter);

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.solitaire when _solitaire != null => SolitairePane(
      solitaire: _solitaire!,
      onNextGame: _modes.viewer.file == null ? null : () => walk(1),
      onAddToStudy: _addGame,
    ),
    WorkspaceTab.filter => ViewerFilterPane(
      viewer: _modes.viewer,
      filter: _modes.filter,
      say: requests.say,
      onSaveToStudy: _addSelection,
      onPosition: _filterByPosition,
    ),
    WorkspaceTab.book when workspace.boardBook != null => BoardBookPane(
      book: workspace.boardBook!,
      session: workspace.session,
      onReadBook: (place) =>
          unawaited(requests.readInBuilder(place.file.ref, place.sans)),
      bookChip: BookChip(books: workspace.books, onEdit: requests.editBooks),
    ),
    _ => null,
  };

  @override
  bool leave() {
    final solitaire = _solitaire;
    if (solitaire == null || !solitaire.active) return false;
    solitaire.stop();
    return true;
  }

  @override
  GameOrdering? get gameOrdering => _modes.viewer;
  @override
  bool walk(int by) {
    if (_modes.viewer.file == null) return false;
    _modes.viewer.walk(by);
    return true;
  }

  @override
  bool get offersNewAnalysis => false;

  /// Moves played here are for looking: they stay off the file until the
  /// user saves them.
  @override
  void entered() => workspace.session.holdsEdits = true;

  /// Nothing would be left to stop it by: Space is the viewer's.
  @override
  void left() {
    _modes.autoplay.stop();
    _solitaire?.stop();
    workspace.session.holdsEdits = false;
  }

  @override
  List<AppAction> actions(ModeMenu menu) {
    final autoplay = _modes.autoplay;
    return [
      ...super
          .actions(menu)
          .where(
            (action) =>
                action.group != 'File' &&
                action.group != 'Panels' &&
                action.label != 'Save a copy…',
          ),
      AppAction(
        workspace.review?.running == true ? 'Stop analysis' : 'Analyze game',
        workspace.session.chapter == null ||
                (_solitaire?.active == true && _solitaire?.finished == false)
            ? null
            : analyze,
        icon: Icons.query_stats,
        group: 'Game',
      ),
      AppAction(
        _solitaire?.active == true ? 'Stop solitaire' : 'Solitaire chess',
        workspace.session.chapter == null || workspace.review?.running == true
            ? null
            : solitaire,
        icon: Icons.psychology_alt_outlined,
        group: 'Game',
      ),
      AppAction(
        autoplay.playing ? 'Stop playing' : 'Play through',
        workspace.session.chapter == null ? null : autoplay.toggle,
        shortcut: AppKey.play.label,
        group: 'Board',
      ),
      AppAction(
        'Add game to study…',
        workspace.session.chapter == null ? null : _addGame,
        group: 'Game',
      ),
      AppAction(
        'Filter games',
        _modes.viewer.file == null ? null : () => show(WorkspaceTab.filter),
        icon: Icons.filter_list,
        group: 'File',
      ),
      AppAction(
        'Export visible games as PGN…',
        _modes.viewer.file == null || _modes.filter.busy
            ? null
            : menu.dialogs.exportPgn,
        group: 'File',
      ),
      AppAction(
        'Save selection to study…',
        _modes.viewer.file == null || _modes.filter.busy ? null : _addSelection,
        group: 'File',
      ),
    ];
  }

  void _addGame() =>
      unawaited(requests.addToStudy([?gameDraft(workspace.session)]));

  void _addSelection() =>
      unawaited(requests.addToStudy(_modes.viewer.selectionDrafts()));

  /// A move's menu adds the line through it to a study.
  @override
  MoveMenu get moveMenu =>
      (path) => [
        MenuItemButton(
          onPressed: () => unawaited(
            requests.addToStudy([?lineDraft(workspace.session, path)]),
          ),
          child: const Text('Add line to study…'),
        ),
      ];

  /// Keeps the games that reach the position on the board, which is the
  /// analysis board's while that is the one shown.
  void _filterByPosition() => _modes.filter.reaching(
    workspace.inspection?.active == true
        ? workspace.inspection!.session.boardFen
        : workspace.session.boardFen,
  );

  @override
  Widget list(Widget toggle) => PgnViewerPanel(
    viewer: _modes.viewer,
    filter: _modes.filter,
    onFilter: () => show(WorkspaceTab.filter),
    onOpen: (file) => unawaited(requests.openFile(file)),
    onBrowse: () => unawaited(requests.browse()),
    trailing: toggle,
  );

  @override
  AppAction get fileEntry => AppAction(
    'Close file',
    _modes.viewer.file == null ? null : () => unawaited(requests.closeFile()),
    group: 'File',
  );
}

/// Study: the studies and their chapters, and the quiz markers a
/// right-click puts on a move.
final class StudyView extends _DocumentModeView {
  StudyView(Workspace workspace, WorkspaceRequests requests, this._modes)
    : super(workspace, readingTabs(), requests);

  final DocumentModes _modes;

  /// The studies are read again each time they come on screen: one
  /// imported or written since is listed.
  @override
  void entered() => unawaited(_modes.studies.refresh());

  @override
  MoveMenu get moveMenu =>
      (path) => quizMenuItems(workspace.session, path);

  @override
  Widget list(Widget toggle) => StudyPanel(
    studies: _modes.studies,
    session: workspace.session,
    onOpen: (study, chapter) => unawaited(requests.open(study, game: chapter)),
    trailing: toggle,
  );

  /// A study opens from the list beside it, not the viewer's, so whatever
  /// is on the board is what there is to close.
  @override
  AppAction get fileEntry => AppAction(
    'Close file',
    workspace.session.source == null
        ? null
        : () => unawaited(requests.closeFile()),
    group: 'File',
  );
}

/// Books: the user's books and what is in each, a screen of its own. A
/// chapter opens in the builder.
final class BooksView extends ModeView {
  BooksView(Workspace workspace, this._requests, this._modes)
    : super(workspace, readingTabs());

  final WorkspaceRequests _requests;
  final DocumentModes _modes;

  @override
  Widget list(Widget toggle) => const SizedBox.shrink();

  /// The repertoires are listed again: one made since is there to tick.
  @override
  void entered() => unawaited(_modes.library.refresh());

  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) =>
      CallbackShortcuts(
        bindings: windowKeys,
        child: Focus(
          autofocus: true,
          child: Builder(
            builder: (context) => BooksScreen(
              books: workspace.books,
              catalog: _modes.library.catalog,
              onOpenChapter: (ref) =>
                  unawaited(_requests.readInBuilder(ref, const [])),
            ),
          ),
        ),
      );

  @override
  Listenable get changes => workspace.books;

  @override
  List<AppAction> actions(ModeMenu menu) => [
    AppAction('New book', menu.dialogs.newBook, group: 'Books'),
  ];
}

/// The Bughouse lab: its own screen, two boards and what Hivemind makes
/// of them, with nothing of the workspace but the window around it. The
/// engine searches only while it is on screen.
final class BughouseView extends ModeView {
  BughouseView(Workspace workspace, this._labs, this._input)
    : super(workspace, readingTabs());

  final LabModes _labs;
  final WindowInput _input;

  @override
  Widget list(Widget toggle) => const SizedBox.shrink();

  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) =>
      BughouseScreen(
        lab: _labs.lab,
        search: _labs.search,
        archive: _labs.archive,
        matches: _labs.matches,
        windowKeys: windowKeys,
      );

  @override
  Listenable get changes =>
      Listenable.merge([_labs.lab, _labs.search, _labs.matches]);

  @override
  void entered() {
    // Stockfish would follow a board nobody sees, on the cores Hivemind is
    // using.
    workspace.analysis.pause(this, _pauseReason);
    _labs.search.open();
    unawaited(_labs.archive.open());
    unawaited(_labs.matches.load());
  }

  @override
  void left() {
    _labs.search.close();
    workspace.analysis.resume(this);
  }

  static const _pauseReason = 'Paused while the Bughouse lab is open';

  @override
  List<AppAction> actions(ModeMenu menu) {
    final lab = _labs.lab;
    final search = _labs.search;
    return [
      AppAction(
        'Toggle engine',
        search.toggleEngine,
        shortcut: AppKey.engine.label,
        group: 'Bughouse',
      ),
      AppAction('New game', lab.newGame, group: 'Bughouse'),
      AppAction('Flip boards', lab.flip, group: 'Bughouse'),
      AppAction(
        lab.showMatches ? 'Back to analysis' : 'Matches',
        lab.toggleMatches,
        group: 'Bughouse',
      ),
      AppAction(
        'Copy dual FEN',
        () => unawaited(
          Clipboard.setData(ClipboardData(text: lab.position.dualFen)),
        ),
        group: 'Position',
      ),
      AppAction(
        'Paste dual FEN',
        () => unawaited(_paste(lab.loadDualFen)),
        group: 'Position',
      ),
      AppAction(
        'Copy moves',
        lab.line.moves.isEmpty
            ? null
            : () => unawaited(
                Clipboard.setData(ClipboardData(text: lab.movesText)),
              ),
        group: 'Position',
      ),
      AppAction(
        'Paste moves',
        () => unawaited(_paste(lab.pasteMoves)),
        group: 'Position',
      ),
    ];
  }

  Future<void> _paste(void Function(String text) into) async {
    final text = await _input.clipboard();
    if (text != null && text.trim().isNotEmpty) into(text);
  }
}

/// The view of each mode, made once for the window.
Map<Mode, ModeView> modeViews({
  required Workspace workspace,
  required WorkspaceRequests requests,
  required DocumentModes documents,
  required TrainingModes training,
  required LabModes labs,
  required PlayerModes players,
  required DatabaseLibrary databases,
  TournamentRun? tournaments,
}) => {
  for (final mode in Mode.values)
    mode: switch (mode) {
      Mode.repertoires => RepertoiresView(workspace, requests, documents),
      Mode.trainer => TrainerView(workspace, requests, documents),
      Mode.books => BooksView(workspace, requests, documents),
      Mode.pgnViewer => ViewerView(workspace, requests, documents),
      Mode.study => StudyView(workspace, requests, documents),
      Mode.tactics => TacticsView(workspace, requests, training),
      Mode.myGames => MyGamesView(workspace, requests, training),
      Mode.bughouse => BughouseView(workspace, labs, requests.input),
      Mode.playerAnalysis => PlayerAnalysisView(workspace, requests, players),
      Mode.players => PlayersView(workspace, players),
      Mode.databases => DatabasesView(workspace, databases, requests),
      Mode.engineTournament => TournamentView(workspace, tournaments, requests),
    },
};

/// The analysis board's doors in the Actions menu: back to it, a new one
/// from the position on the board, and — while it is up — a paste onto it
/// and the two ways to keep it. Each way to keep it asks two questions, one
/// dialog each: where, then what to call it.
List<AppAction> boardActions(
  BuildContext context, {
  required DocumentSession session,
  required WorkspaceRequests requests,
  required Library library,
  required VoidCallback? onAnalyze,
}) {
  final scratch = session.isScratch;
  return [
    if (onAnalyze != null)
      AppAction(
        'Open Analysis tab',
        onAnalyze,
        shortcut: AppKey.analysisBoard.label,
        group: 'Board',
      ),
    // On the board, Paste PGN or FEN below takes a FEN too.
    if (!scratch)
      AppAction(
        'Paste FEN',
        () => unawaited(requests.pasteFen()),
        shortcut: AppKey.pastePosition.label,
        group: 'File',
      ),
    if (scratch) ...[
      AppAction(
        'Paste PGN or FEN',
        () => unawaited(requests.pasteOntoBoard()),
        shortcut: AppKey.paste.label,
        group: 'File',
      ),
      if (requests.mode == Mode.repertoires)
        AppAction(
          'Save to repertoire…',
          () => unawaited(_toRepertoire(context, requests, library)),
          group: 'Document',
        ),
      if (requests.mode == Mode.study)
        AppAction(
          'Save to study…',
          () => unawaited(requests.addToStudy([?gameDraft(session)])),
          group: 'Document',
        ),
    ],
  ];
}

Future<void> _toRepertoire(
  BuildContext context,
  WorkspaceRequests requests,
  Library library,
) async {
  final into = await showChoiceDialog<RepertoireFolder>(
    context,
    title: 'Save to repertoire',
    options: library.repertoires,
    label: (folder) => folder.name,
    hint: 'Type a repertoire',
    empty: 'No repertoires yet',
  );
  if (into == null || !context.mounted) return;
  final name = await _chapterName(context, into.name);
  if (name == null) return;
  await requests.saveBoardToRepertoire(into, name);
}

/// Save, Ctrl+S and Save changes: the held edits into their file, or, for a
/// file this app may not write, into a copy in [collections] or a new
/// chapter of a study, whichever the user picks.
Future<void> saveHeld(
  BuildContext context, {
  required DocumentSession session,
  required WorkspaceRequests requests,
  required String collections,
}) async {
  if (session.readOnly == null) return session.keepHeld();
  final where = await showDialog<_HeldTarget>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Save your moves'),
      children: [
        for (final target in _HeldTarget.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, target),
            child: Text(target.label),
          ),
      ],
    ),
  );
  if (where == null || !context.mounted) return;
  switch (where) {
    case _HeldTarget.copy:
      final name = await showCopyNameDialog(
        context,
        session.chapter?.name ?? 'Chapter',
      );
      if (name == null) return;
      sayCopy(requests.say, await session.saveCopy(name, into: collections));
    case _HeldTarget.study:
      await requests.addToStudy([?gameDraft(session)]);
  }
}

enum _HeldTarget {
  copy('Copy into Documents…'),
  study('Add to a study…');

  const _HeldTarget(this.label);
  final String label;
}

Future<String?> _chapterName(BuildContext context, String into) async {
  if (!context.mounted) return null;
  return showNameDialog(
    context,
    title: 'New chapter in $into',
    label: 'Chapter name',
    confirm: 'Save',
  );
}
