import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../chess/book/book_check.dart' show BookPlace;
import '../chess/tactics/puzzle.dart';
import '../features/books/books_screen.dart';
import '../features/bughouse/bughouse_screen.dart';
import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../features/my_games/book_pane.dart';
import '../features/my_games/game_book.dart';
import '../features/my_games/my_games_panel.dart';
import '../features/pgn_viewer/pgn_viewer_panel.dart';
import '../features/study/studies.dart';
import '../features/study/study_panel.dart';
import '../features/tactics/my_games_block.dart';
import '../features/tactics/puzzle_pane.dart';
import '../features/tactics/tactics_actions.dart';
import '../features/tactics/tactics_panel.dart';
import '../storage/chapter_files.dart';
import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/name_dialog.dart';
import '../ui/pane_tabs.dart';
import '../workspace/book_chip.dart';
import '../workspace/chapter_commands.dart';
import '../workspace/document_actions.dart';
import '../workspace/document_session.dart';
import '../workspace/move_tree_view.dart' show MoveMenu;
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// What the window's own dialogs do, which the shell runs: they need its
/// context. The Actions menu only points at them.
typedef ShellDialogs = ({
  VoidCallback saveCopy,
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
  ModeView(this.workspace, this.tabs);

  final Workspace workspace;

  /// The reading card's tabs in this mode: which are open and which is up.
  final PaneTabs<WorkspaceTab> tabs;

  /// The left column, with [toggle] — the `«` that hides it — in its corner.
  Widget list(Widget toggle);

  /// Everything the Actions menu offers in this mode now.
  List<AppAction> actions(ModeMenu menu);

  /// What the entries' enabled states read, heard only while the menu is
  /// open.
  Listenable get changes;

  /// Whether the card is headed with the game's players.
  bool get header => true;

  /// Whether the board has the file's game counter under it.
  bool get gameCounter => true;

  /// Whether the Train tab offers to read a line in the builder: from
  /// anywhere but the builder itself.
  bool get offersBuilder => true;

  /// What a right-click on a move offers.
  MoveMenu? get moveMenu => null;

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

  void dispose() => tabs.dispose();

  /// What can be done to the document on the board, in every mode that
  /// shows one as a document.
  List<AppAction> documentEntries(ModeMenu menu) => documentActions(
    session: workspace.session,
    analysis: workspace.analysis,
    editing: menu.editing,
    onSaveCopy: menu.dialogs.saveCopy,
  );
}

/// The three modes whose list opens a document: the builder, the viewer and
/// Study. They share the Actions menu and differ in the list and in the one
/// file entry.
abstract base class _DocumentModeView extends ModeView {
  _DocumentModeView(super.workspace, super.tabs, this.requests);

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
      shortcut: 'Ctrl+O',
      group: 'File',
    ),
    fileEntry,
    ..._repertoire(menu.dialogs),
    ...documentEntries(menu),
    ...menu.board(),
    ...tabActions(tabs),
  ];

  /// The chapter as a repertoire — its gaps, its side and the fill — or,
  /// on the analysis board, the search from it.
  List<AppAction> _repertoire(ShellDialogs dialogs) {
    final session = workspace.session;
    return [
      AppAction(
        'Search from here',
        workspace.fill.canStart ? dialogs.search : null,
        shortcut: 'Ctrl+G',
        group: 'Repertoire',
      ),
      AppAction(
        'Train this chapter',
        session.chapter == null ? null : () => tabs.show(WorkspaceTab.train),
        group: 'Repertoire',
      ),
      AppAction(
        'Next gap',
        workspace.gaps.canNextGap ? workspace.gaps.nextGap : null,
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
  ) : super(workspace, newWorkspaceTabs(), requests, modes);

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
  void entered() => tabs.show(WorkspaceTab.train);
}

/// The files the PGN Viewer has open or has had open.
final class ViewerView extends _DocumentModeView {
  ViewerView(Workspace workspace, WorkspaceRequests requests, this._modes)
    : super(workspace, readingTabs(), requests);

  final DocumentModes _modes;

  @override
  Listenable get changes =>
      Listenable.merge([super.changes, _modes.viewer, _modes.autoplay]);

  @override
  void space() => _modes.autoplay.toggle();

  /// Moves played here are for looking: they stay off the file until the
  /// user saves them.
  @override
  void entered() => workspace.session.holdsEdits = true;

  /// Nothing would be left to stop it by: Space is the viewer's.
  @override
  void left() {
    _modes.autoplay.stop();
    workspace.session.holdsEdits = false;
  }

  @override
  List<AppAction> actions(ModeMenu menu) {
    final autoplay = _modes.autoplay;
    return [
      ...super.actions(menu),
      AppAction(
        autoplay.playing ? 'Stop playing' : 'Play through',
        workspace.session.chapter == null ? null : autoplay.toggle,
        shortcut: 'Space',
        group: 'Board',
      ),
    ];
  }

  @override
  Widget list(Widget toggle) => PgnViewerPanel(
    viewer: _modes.viewer,
    filter: _modes.filter,
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

/// Tactics: the puzzle set on the left, the puzzle and the game it came
/// from on the card. It is for solving, so it starts with the engine off
/// and neither heads the card nor counts the file's games: the puzzle says
/// whose game it was and the list is the way to another.
final class TacticsView extends ModeView {
  TacticsView(Workspace workspace, this._training)
    : super(workspace, puzzleTabs());

  final TrainingModes _training;

  @override
  bool get header => false;

  @override
  bool get gameCounter => false;

  @override
  Listenable get changes => Listenable.merge([
    workspace.session,
    workspace.analysis,
    _training.puzzles,
    _training.myGames,
  ]);

  @override
  void entered() {
    if (workspace.analysis.enabled) unawaited(workspace.analysis.disable());
  }

  /// Esc ends the sitting, as the old app's Esc left the puzzle.
  @override
  bool leave() {
    final puzzles = _training.puzzles;
    if (puzzles.run == null) return false;
    puzzles.end();
    return true;
  }

  /// Starts a sitting, from [first] when the list asked for one, with the
  /// Puzzle tab up.
  void _play({Puzzle? first}) {
    tabs.show(WorkspaceTab.puzzle);
    final puzzles = _training.puzzles;
    unawaited(first == null ? puzzles.start() : puzzles.show(first));
  }

  /// The solved puzzle's game with the engine on: the Game tab, not
  /// another mode.
  void _analyze() {
    tabs.show(WorkspaceTab.moves);
    unawaited(workspace.analysis.enable());
  }

  @override
  Widget list(Widget toggle) => TacticsPanel(
    set: _training.tactics,
    trainer: _training.puzzles,
    myGames: _training.myGames,
    onPlay: _play,
    trailing: toggle,
  );

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) =>
      tab == WorkspaceTab.puzzle
      ? PuzzlePane(trainer: _training.puzzles, onAnalyze: _analyze)
      : null;

  @override
  List<AppAction> actions(ModeMenu menu) => tacticsActions(
    trainer: _training.puzzles,
    games: _training.myGames,
    session: workspace.session,
    analysis: workspace.analysis,
    tabs: tabs,
    onAccounts: menu.dialogs.accounts,
  );
}

/// My games: the user's games read against their repertoires. ↑ and ↓
/// walk its own list, not the saved file's order, so the board has no
/// game counter; a game opens at the moment its verdict is about.
final class MyGamesView extends ModeView {
  MyGamesView(Workspace workspace, this._requests, this._training)
    : super(workspace, bookTabs());

  final WorkspaceRequests _requests;
  final TrainingModes _training;

  GameBook get _book => _training.book;

  @override
  bool get gameCounter => false;

  @override
  Listenable get changes => Listenable.merge([
    workspace.session,
    workspace.saver,
    workspace.analysis,
    _training.myGames,
    _book,
  ]);

  /// The game on the board, seen from the user's side, at its moment.
  void _open(CheckedGame checked) => unawaited(
    _requests.openGame(
      checked.file,
      game: checked.game.index,
      ply: checked.moment,
      side: checked.game.side,
    ),
  );

  /// The file of the book at [place], in the builder.
  void _readBook(BookPlace place) =>
      unawaited(_requests.readInBuilder(place.file.ref, place.sans));

  @override
  bool walk(int by) {
    final session = workspace.session;
    final next = _book.step(session.source, session.game, by);
    if (next != null) _open(next);
    return true;
  }

  @override
  Widget list(Widget toggle) => MyGamesPanel(
    book: _book,
    session: workspace.session,
    accounts: MyGamesBlock(games: _training.myGames),
    bookChip: BookChip(books: workspace.books, onEdit: _requests.editBooks),
    onOpen: _open,
    trailing: toggle,
  );

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) =>
      tab == WorkspaceTab.book
      ? BookPane(book: _book, session: workspace.session, onReadBook: _readBook)
      : null;

  @override
  List<AppAction> actions(ModeMenu menu) => [
    ...myGamesActions(_training.myGames, onAccounts: menu.dialogs.accounts),
    ...documentEntries(menu),
    ...tabActions(tabs),
  ];
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
  BughouseView(Workspace workspace, this._labs)
    : super(workspace, readingTabs());

  final LabModes _labs;

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
        shortcut: 'E',
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
      AppAction('Paste dual FEN', () => unawaited(_paste()), group: 'Position'),
    ];
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.trim().isNotEmpty) _labs.lab.loadDualFen(text);
  }
}

/// The view of each mode, made once for the window.
Map<Mode, ModeView> modeViews({
  required Workspace workspace,
  required WorkspaceRequests requests,
  required DocumentModes documents,
  required TrainingModes training,
  required LabModes labs,
}) => {
  for (final mode in Mode.values)
    mode: switch (mode) {
      Mode.repertoires => RepertoiresView(workspace, requests, documents),
      Mode.trainer => TrainerView(workspace, requests, documents),
      Mode.books => BooksView(workspace, requests, documents),
      Mode.pgnViewer => ViewerView(workspace, requests, documents),
      Mode.study => StudyView(workspace, requests, documents),
      Mode.tactics => TacticsView(workspace, training),
      Mode.myGames => MyGamesView(workspace, requests, training),
      Mode.bughouse => BughouseView(workspace, labs),
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
  required Studies studies,
}) {
  final scratch = session.isScratch;
  return [
    AppAction(
      'Analysis board',
      scratch ? null : () => unawaited(requests.analysisBoard()),
      group: 'Analysis board',
    ),
    AppAction(
      'New analysis board from here',
      () => unawaited(requests.newAnalysisBoard()),
      shortcut: 'Ctrl+N',
      group: 'Analysis board',
    ),
    // On the board, Paste PGN or FEN below takes a FEN too.
    if (!scratch)
      AppAction(
        'Paste FEN',
        () => unawaited(requests.pasteFen()),
        shortcut: 'Ctrl+Shift+V',
        group: 'File',
      ),
    if (scratch) ...[
      AppAction(
        'Paste PGN or FEN',
        () => unawaited(requests.pasteOntoBoard()),
        shortcut: 'Ctrl+V',
        group: 'File',
      ),
      AppAction(
        'Save to repertoire…',
        () => unawaited(_toRepertoire(context, requests, library)),
        group: 'Document',
      ),
      AppAction(
        'Save to study…',
        () => unawaited(_toStudy(context, requests, studies)),
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

Future<void> _toStudy(
  BuildContext context,
  WorkspaceRequests requests,
  Studies studies,
) async {
  final study = await showChoiceDialog<ChapterRef>(
    context,
    title: 'Save to study',
    options: studies.studies,
    label: (study) => study.name,
    hint: 'Type a study',
    empty: 'No studies yet',
  );
  if (study == null || !context.mounted) return;
  final name = await _chapterName(context, study.name);
  if (name == null) return;
  await requests.saveBoardToStudy(study, name);
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
