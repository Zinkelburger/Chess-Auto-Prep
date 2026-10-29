import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/explorer_choice.dart';
import '../chess/pgn/game_tree.dart' show NodePath;
import '../features/library/library_panel.dart';
import '../features/pgn_viewer/filter_pane.dart';
import '../features/pgn_viewer/pgn_viewer_panel.dart';
import '../features/pgn_viewer/player_side_choice.dart';
import '../features/study/quiz_menu.dart';
import '../features/study/study_panel.dart';
import '../features/trainer/trainer.dart';
import '../features/trainer/trainer_state.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../ui/theme.dart';
import '../workspace/book/board_book.dart';
import '../workspace/book/board_book_pane.dart';
import '../workspace/book/book_chip.dart';
import '../workspace/book/repertoire_shelf.dart' show BookFileRef;
import '../workspace/document/chapter_commands.dart';
import '../workspace/document/document_actions.dart';
import '../workspace/document/game_ordering.dart';
import '../workspace/reading/move_tree_view.dart' show MoveMenu;
import '../workspace/review/solitaire.dart';
import '../workspace/review/solitaire_pane.dart';
import '../workspace/document/study_drafts.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

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
    super.analysisInPanes,
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
/// As in the viewer, a tool picked while the card is one pane opens under
/// it, so the moves or the lesson stay in view.
abstract base class _LibraryView extends _DocumentModeView {
  _LibraryView(
    super.workspace,
    super.tabs,
    super.requests,
    this._modes, {
    super.analysisInPanes,
  }) : super(opensBeside: true);

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
    'Paste PGN as repertoire',
    () => unawaited(requests.pasteRepertoire()),
    // On the analysis board Ctrl+V pastes onto the board instead.
    shortcut: workspace.session.isScratch ? null : AppKey.paste.label,
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
  ) : super(workspace, trainerTabs(), requests, modes, analysisInPanes: true);

  /// Coming here is coming to train, whichever tab was left up.
  @override
  void entered() => show(WorkspaceTab.train);
}

/// The PGN Viewer and Study: one card for reading a game and editing it.
/// `Read | Edit` at the foot of the card is the one difference in what a
/// move does there. Reading, the board is quiet and what is done on it is
/// held off the file until saved; editing, the board has its tools and
/// every change is written as it is made, the held ones first. A file
/// this app may not write holds edits either way, for Save to place.
/// Each mode remembers its own side of the switch.
abstract base class _ReadingView extends _DocumentModeView {
  _ReadingView(
    super.workspace,
    super.tabs,
    super.requests,
    this._modes,
    this.editing, {
    super.explorer,
  }) : super(opensBeside: true);

  final DocumentModes _modes;
  final ValueNotifier<bool> editing;

  Solitaire? get _solitaire => workspace.solitaire;

  @override
  bool get editSwitch => true;

  @override
  Listenable get changes => Listenable.merge([
    super.changes,
    _modes.autoplay,
    ?workspace.review,
    ?_solitaire,
  ]);

  @override
  void entered() {
    editing.addListener(_switched);
    workspace.session.addListener(_hold);
    _hold();
  }

  @override
  void left() {
    editing.removeListener(_switched);
    workspace.session.removeListener(_hold);
    _modes.autoplay.stop();
    _solitaire?.stop();
    workspace.session.holdsEdits = false;
  }

  /// Turning to Edit writes what reading held: the switch is the user
  /// saying they want what is on screen. Another mode or document coming
  /// up never does, so its edits are not written by arriving.
  void _switched() {
    final session = workspace.session;
    if (editing.value && session.readOnly == null && session.hasHeldEdits) {
      session.keepHeld();
    }
    _hold();
  }

  void _hold() => workspace.session.holdsEdits =
      !editing.value || workspace.session.readOnly != null;

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

  /// Shows the Game review tab and reviews every game of the file.
  void _analyzeAll() {
    show(WorkspaceTab.review);
    unawaited(workspace.review?.startAll());
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

  /// Reading, a file is a book: what is not in use is not under the board.
  @override
  bool get quietBoard => !editing.value;

  /// The engine, which a quiet board has no control on screen for: here
  /// with its key, so it can be found.
  @override
  List<AppAction> paneActions(ValueNotifier<bool> editing) => [
    for (final action in documentActions(
      session: workspace.session,
      analysis: workspace.analysis,
      editing: editing,
      onSaveCopy: () {},
    ))
      if (action.shortcut == AppKey.engine.label) action,
  ];

  /// After a solitaire game, the next one to play: the next game of the
  /// file, or null when there is none to go to.
  VoidCallback? get _nextGame;

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.solitaire when _solitaire != null => SolitairePane(
      solitaire: _solitaire!,
      onNextGame: _nextGame,
      onAddToStudy: () {
        final draft = _solitaire!.reviewDraft;
        if (draft != null) unawaited(requests.addToStudy([draft]));
      },
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

  /// Moves played on the board are already off the file while reading,
  /// and the Analysis tab holds a scratch copy of the game.
  @override
  bool get offersNewAnalysis => false;

  /// The same file in the other mode, on the same game.
  AppAction get _otherMode;

  @override
  List<AppAction> actions(ModeMenu menu) {
    final autoplay = _modes.autoplay;
    final open = workspace.session.chapter != null;
    return [
      ...super.actions(menu).where(_keeps),
      AppAction(
        workspace.review?.running == true ? 'Stop analysis' : 'Analyze game',
        !open || (_solitaire?.active == true && _solitaire?.finished == false)
            ? null
            : analyze,
        icon: Icons.query_stats,
        group: 'Game',
      ),
      AppAction(
        'Analyze all games',
        workspace.review?.canReviewAll == true ? _analyzeAll : null,
        icon: Icons.query_stats,
        group: 'Game',
      ),
      AppAction(
        _solitaire?.active == true ? 'Stop solitaire' : 'Solitaire chess',
        !open || workspace.review?.running == true ? null : solitaire,
        icon: Icons.psychology_alt_outlined,
        group: 'Game',
      ),
      AppAction(
        autoplay.playing ? 'Stop playing' : 'Play through',
        open ? autoplay.toggle : null,
        shortcut: AppKey.play.label,
        group: 'Board',
      ),
      AppAction('Add game to study…', open ? _addGame : null, group: 'Game'),
      _otherMode,
    ];
  }

  /// Whether the menu keeps one of the document actions every mode with
  /// a file offers.
  bool _keeps(AppAction action) => true;

  void _addGame() =>
      unawaited(requests.addToStudy([?gameDraft(workspace.session)]));

  /// A move's menu adds the line through it to a study.
  List<Widget> _addLine(NodePath path) => [
    MenuItemButton(
      onPressed: () =>
          unawaited(requests.addToStudy([?lineDraft(workspace.session, path)])),
      leadingIcon: const Icon(Icons.playlist_add, size: IconSize.menu),
      child: const Text('Add line to study…'),
    ),
  ];
}

/// The files the PGN Viewer has open or has had open.
final class ViewerView extends _ReadingView {
  ViewerView(
    Workspace workspace,
    WorkspaceRequests requests,
    DocumentModes modes,
    ValueNotifier<bool> editing,
  ) : super(
        workspace,
        viewerTabs(),
        requests,
        modes,
        editing,
        // What is played in the file being read comes first here; the
        // databases are a click away.
        explorer: workspace.explorer.independent(
          starting: ExplorerSource.thisFile,
        ),
      );

  @override
  Listenable get changes => Listenable.merge([super.changes, _modes.viewer]);

  @override
  Widget? get explorerFileBar =>
      PlayerSideChoice(viewer: _modes.viewer, filter: _modes.filter);

  @override
  VoidCallback? get _nextGame =>
      _modes.viewer.file == null ? null : () => walk(1);

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.filter => ViewerFilterPane(
      viewer: _modes.viewer,
      filter: _modes.filter,
      say: requests.say,
      onSaveToStudy: _addSelection,
      onPosition: _filterByPosition,
    ),
    _ => super.tab(context, tab),
  };

  @override
  GameOrdering? get gameOrdering => _modes.viewer;
  @override
  bool walk(int by) {
    if (_modes.viewer.file == null) return false;
    _modes.viewer.walk(by);
    return true;
  }

  /// A study read here goes to Study on the same chapter.
  @override
  AppAction get _otherMode =>
      AppAction('Open in Study', switch (_modes.studies.open) {
        final study? => () => unawaited(
          requests.openStudy(study, chapter: workspace.session.game ?? 0),
        ),
        null => null,
      }, group: 'File');

  /// A file is read here, not opened or kept as a copy: its File actions
  /// are the games list's own.
  @override
  bool _keeps(AppAction action) =>
      action.group != 'File' &&
      action.group != 'Panels' &&
      action.label != 'Save a copy…';

  @override
  List<AppAction> actions(ModeMenu menu) => [
    ...super.actions(menu),
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

  void _addSelection() =>
      unawaited(requests.addToStudy(_modes.viewer.selectionDrafts()));

  @override
  MoveMenu get moveMenu => _addLine;

  /// Keeps the games that reach the position on the board, which is the
  /// analysis board's while that is the one shown.
  void _filterByPosition() => _modes.filter.reaching(
    workspace.inspection?.active == true
        ? workspace.inspection!.session.cursor.boardFen
        : workspace.session.cursor.boardFen,
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
/// right-click puts on a move. It opens on Edit: a study is written in.
final class StudyView extends _ReadingView {
  StudyView(
    Workspace workspace,
    WorkspaceRequests requests,
    DocumentModes modes,
    ValueNotifier<bool> editing,
    this._trainer, {
    this.lichessLogin,
  }) : super(workspace, studyTabs(), requests, modes, editing);

  final Trainer _trainer;

  /// The Lichess login a send to Lichess may need.
  final Future<bool> Function(BuildContext)? lichessLogin;

  @override
  bool get offersBuilder => false;

  @override
  bool get startsEditing => true;

  @override
  bool get studyTools => true;

  void train() {
    _trainer.setScope(TrainScope.chapter);
    show(WorkspaceTab.train);
  }

  /// The studies are read again each time they come on screen: one
  /// imported or written since is listed.
  @override
  void entered() {
    super.entered();
    _trainer.setScope(TrainScope.chapter);
    unawaited(_modes.studies.refresh());
  }

  @override
  VoidCallback? get _nextGame {
    final session = workspace.session;
    final at = session.game;
    final count = session.gameCount;
    if (at == null || count == null || at + 1 >= count) return null;
    return session.nextGame;
  }

  /// The chapter in the PGN Viewer, to read it with the file's games list.
  @override
  AppAction get _otherMode =>
      AppAction('Read in PGN Viewer', switch (workspace.session.source) {
        final study? => () => unawaited(
          requests.readInViewer(study, game: workspace.session.game),
        ),
        null => null,
      }, group: 'File');

  @override
  MoveMenu get moveMenu =>
      (path) => [...quizMenuItems(workspace.session, path), ..._addLine(path)];

  @override
  Widget list(Widget toggle) => StudyPanel(
    studies: _modes.studies,
    onTrain: train,
    session: workspace.session,
    onOpen: (study, chapter) => unawaited(requests.open(study, game: chapter)),
    onLichessLogin: lichessLogin,
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
