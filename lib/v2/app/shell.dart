import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../features/library/outline_panel.dart';
import '../features/settings/setting_rows.dart';
import '../features/settings/settings_dialog.dart';
import '../features/tactics/my_games_block.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/trainer/train_pane.dart';
import '../features/trainer/trainer.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/error_bar.dart';
import '../ui/listening_state.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import '../workspace/board_claim.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/move_field.dart';
import '../workspace/tree_pane.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_keys.dart';
import '../workspace/workspace_tabs.dart';
import '../workspace/workspace_view.dart';
import 'full_screen.dart';
import 'mode_view.dart';
import 'mode.dart';
import 'top_bar.dart';
import 'workspace_requests.dart';

/// The window: a top bar with the mode menu and the Actions menu, the
/// mode's list on the left and the workspace filling the rest. What the
/// lists, the explorer and the keys ask for across modes goes to
/// [WorkspaceRequests]; this draws its mode and its status and wires the
/// panels to it.
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.requests,
    required this.workspace,
    required this.documents,
    required this.training,
    required this.labs,
    required this.fullScreen,
    required this.settingRows,
    required this.settingsAlso,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;
  final DocumentModes documents;
  final TrainingModes training;
  final LabModes labs;

  /// Whether the window fills the screen: F11, Esc and the Actions menu.
  final FullScreen fullScreen;

  /// The settings page's rows, as the app wires them, and the one owner
  /// besides the store they are built from: the Lichess account.
  final List<SettingGroup> Function() settingRows;
  final Listenable settingsAlso;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with ListeningState<Shell> {
  /// Whether the edit strip is open. The strip's own Done closes it.
  final _editing = ValueNotifier(false);

  /// The words and the focus of the move field under the board, which `/`
  /// and a lesson reach as well as the field.
  final _moves = MoveEntry();

  /// Who holds the board: a lesson first, then the Tree tab's free board.
  late final _claim = FirstClaim([_train.lines.board, _ws.tree.board]);

  /// Each mode's list, tabs, Actions menu and what it adds to the
  /// workspace; the window asks the one on screen.
  late final _views = modeViews(
    workspace: _ws,
    requests: _requests,
    documents: _docs,
    training: _train,
    labs: widget.labs,
  );

  ModeView get _view => _views[_requests.mode]!;

  /// The mode on screen as last seen, so the one left and the one come to
  /// can be told: the mode changes through the requests, whoever asked —
  /// the mode menu, or a list that opens its file in another mode.
  Mode? _shown;

  void _modeMayHaveChanged() {
    final mode = _requests.mode;
    if (mode == _shown) return;
    if (_shown case final left?) _views[left]!.left();
    _shown = mode;
    _views[mode]!.entered();
  }

  /// The reading card's tabs of the mode on screen.
  PaneTabs<WorkspaceTab> get _tabs => _view.tabs;

  late final _sitting = SittingInView(
    trainer: _train.lines,
    requests: _requests,
    trainTabOpen: () => _tabs.open.contains(WorkspaceTab.train),
  );
  late final _puzzle = PuzzleInView(
    puzzles: _train.puzzles,
    requests: _requests,
  );

  /// The columns and their widths. The user drags the dividers; the list
  /// column goes when hidden and the outline column comes and goes with the
  /// chapter, and the widths of the others stay what the user made them.
  /// The areas are the same three objects for the life of the window: the
  /// split view keys each pane by its area, and a pane rebuilt from a new
  /// area loses what it had open.
  final _panes = MultiSplitViewController();
  // The list starts as narrow as it goes: the board is what the window is
  // for, and the divider is there for whoever wants more of the list.
  final _list = Area(data: _Pane.list, size: paneMinWidth, min: paneMinWidth);
  final _outline = Area(
    data: _Pane.outline,
    size: outlineColumnWidth,
    min: paneMinWidth,
  );
  final _workspace = Area(
    data: _Pane.workspace,
    flex: 1,
    min: boardPaneMinWidth,
  );
  bool _outlineShown = false;
  bool _listShown = true;

  WorkspaceRequests get _requests => widget.requests;
  Workspace get _ws => widget.workspace;
  DocumentModes get _docs => widget.documents;
  TrainingModes get _train => widget.training;

  @override
  void initState() {
    super.initState();
    _outlineShown = _wantsOutline;
    _arrange();
    for (final view in _views.values) {
      view.tabs.addListener(_sitting.check);
    }
    _sitting.check();
    _puzzle.check();
    _shown = _requests.mode;
    _requests.addListener(_modeMayHaveChanged);
  }

  @override
  void dispose() {
    _requests.removeListener(_modeMayHaveChanged);
    _sitting.dispose();
    _puzzle.dispose();
    _editing.dispose();
    _moves.dispose();
    _claim.dispose();
    for (final view in _views.values) {
      view.dispose();
    }
    _panes.dispose();
    super.dispose();
  }

  void _arrange() => _panes.areas = [
    if (_listShown) _list,
    if (_outlineShown) _outline,
    _workspace,
  ];

  /// The outline is a repertoire chapter's lines, so it is there only when
  /// a chapter that is a whole file is open. A study chapter is one game of
  /// its file, its chapters are already in its own left column, and the line
  /// operations do not mean the same thing there — so it has no outline,
  /// whichever mode the user switches to.
  bool get _wantsOutline =>
      _ws.session.source != null && _ws.session.game == null;

  @override
  Listenable listenableOf(Shell widget) => widget.workspace.session;

  /// Puts the outline column in or takes it out when the open chapter
  /// changes what is wanted. The other two panes are left alone, so the
  /// list keeps its width and whatever it has open.
  @override
  void changed() {
    if (_wantsOutline == _outlineShown) return;
    _outlineShown = _wantsOutline;
    _arrange();
  }

  late final _search = SearchDoor(
    fill: _ws.fill,
    settings: _ws.settings,
    requests: _requests,
  );

  /// A line the Train tab sent to be read: its chapter on the board at the
  /// position, the builder first when it asked for it, and the Moves tab up
  /// unless only the board was to move.
  Future<void> _readLine(LineToRead line) async {
    if (line.place == ReadIn.builder) _requests.switchTo(Mode.repertoires);
    final result = await _requests.openAt(line.ref, line.sans);
    if (!mounted || result is! RequestDone) return;
    if (line.place != ReadIn.board) _tabs.show(WorkspaceTab.moves);
  }

  /// While the Tree tab is up the board is its free board; otherwise a
  /// move on the board is the puzzle's, or the document's.
  void _boardMove(String uci) =>
      _ws.tree.watching ? _ws.tree.play(uci) : _train.puzzles.play(uci);

  /// A clicked engine line's moves: onto the free board while the Tree tab
  /// is up, into the document otherwise.
  void _engineMove(String uci) =>
      _ws.tree.watching ? _ws.tree.play(uci) : _ws.session.playMove(uci);

  /// The body of a tab the workspace does not draw: the mode's own first,
  /// then the Train and Tree tabs every mode that has them shares.
  Widget? _tabBody(BuildContext context, WorkspaceTab tab) =>
      _view.tab(context, tab) ??
      switch (tab) {
        WorkspaceTab.train => TrainPane(
          trainer: _train.lines,
          moves: _moves,
          onRead: (line) => unawaited(_readLine(line)),
          offerBuilder: _view.offersBuilder,
        ),
        WorkspaceTab.tree => TreePane(
          session: _ws.session,
          tree: _ws.tree,
          // The file a move was found in: that file, in the builder, at the
          // position the move leads to.
          onOpen: (place) =>
              unawaited(_requests.readInBuilder(place.ref, place.sans)),
        ),
        _ => null,
      };

  /// Space shows the answer while a puzzle is on the board; otherwise it
  /// is the mode's: the viewer's autoplay.
  void _space() {
    if (_train.puzzles.up == null) return _view.space();
    _train.puzzles.showSolution();
  }

  /// What Esc leaves once the workspace has nothing left: the mode's
  /// sitting, then full screen.
  bool _leave() => _view.leave() || widget.fullScreen.leave();

  /// ↓ (1) / ↑ (−1) walk what is in front of the user: the mode's own list
  /// when it has one (My games), the puzzles in a sitting, else the file's
  /// games.
  void _walk(int by) {
    if (_view.walk(by)) return;
    final trainer = _train.puzzles;
    if (trainer.up != null) {
      unawaited(by > 0 ? trainer.next() : trainer.previous());
    } else {
      by > 0 ? _ws.session.nextGame() : _ws.session.previousGame();
    }
  }

  void _toggleList() {
    if (!mounted) return;
    setState(() => _listShown = !_listShown);
    _arrange();
  }

  Future<void> _saveCopy() async {
    final name = await showCopyNameDialog(
      context,
      _ws.session.chapter?.name ?? 'Chapter',
    );
    if (name == null || !mounted) return;
    final result = await _ws.session.saveCopy(name);
    if (!mounted) return;
    _requests.say(copySaid(result));
  }

  /// Everything the Actions menu offers now, in the mode on screen.
  List<AppAction> _actions() => [
    ..._modeActions(),
    AppAction(
      widget.fullScreen.on ? 'Leave full screen' : 'Full screen',
      widget.fullScreen.toggle,
      shortcut: 'F11',
      group: 'Window',
    ),
  ];

  List<AppAction> _modeActions() => _view.actions((
    editing: _editing,
    board: () => boardActions(
      context,
      session: _ws.session,
      requests: _requests,
      library: _docs.library,
      studies: _docs.studies,
    ),
    dialogs: (
      saveCopy: () => unawaited(_saveCopy()),
      search: () => unawaited(_search.search(_tabs)),
      accounts: () => unawaited(editAccounts(context, _train.myGames)),
    ),
  ));

  /// The same actions, typed for: a searchable list that the enter key
  /// takes the one match of.
  Future<void> _palette() async {
    final actions = [
      for (final a in _actions())
        if (a.run != null) a,
    ];
    final chosen = await showChoiceDialog<AppAction>(
      context,
      title: 'Actions',
      options: actions,
      label: (action) => action.labelWithKey,
      hint: 'Type an action',
      empty: 'Nothing to do yet',
    );
    chosen?.run?.call();
  }

  Future<void> _settings() => showSettingsDialog(
    context,
    store: _ws.settings,
    groups: widget.settingRows,
    also: widget.settingsAlso,
  );

  Map<ShortcutActivator, VoidCallback> get _windowKeys => {
    // ← takes back a move made past the file on the Tree tab's free board
    // before it steps back in the file.
    const SingleActivator(LogicalKeyboardKey.arrowLeft): _ws.tree.back,
    ..._command(LogicalKeyboardKey.comma, () => unawaited(_settings())),
    ..._command(LogicalKeyboardKey.keyB, _toggleList),
    ..._command(
      LogicalKeyboardKey.keyO,
      () => unawaited(_requests.openPgnFile()),
    ),
    ..._command(LogicalKeyboardKey.keyV, () => unawaited(_requests.paste())),
    ..._command(
      LogicalKeyboardKey.keyV,
      () => unawaited(_requests.pasteFen()),
      shift: true,
    ),
    ..._command(
      LogicalKeyboardKey.keyN,
      () => unawaited(_requests.newAnalysisBoard()),
    ),
    ..._command(
      LogicalKeyboardKey.keyG,
      () => unawaited(_search.search(_tabs)),
    ),
    ..._command(LogicalKeyboardKey.keyK, () => unawaited(_palette())),
    const SingleActivator(LogicalKeyboardKey.space): _space,
    const SingleActivator(LogicalKeyboardKey.f11): widget.fullScreen.toggle,
    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _walk(1),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _walk(-1),
  };

  /// The window's keys a mode with a screen of its own keeps: the settings,
  /// the actions typed for and full screen. The rest are the workspace's.
  Map<ShortcutActivator, VoidCallback> get _screenKeys => {
    const SingleActivator(LogicalKeyboardKey.f11): widget.fullScreen.toggle,
    ..._command(LogicalKeyboardKey.comma, () => unawaited(_settings())),
    ..._command(LogicalKeyboardKey.keyK, () => unawaited(_palette())),
  };

  /// [key] with Ctrl, and with Cmd for macOS; with Shift too when [shift].
  static Map<ShortcutActivator, VoidCallback> _command(
    LogicalKeyboardKey key,
    VoidCallback run, {
    bool shift = false,
  }) => {
    SingleActivator(key, control: true, shift: shift): run,
    SingleActivator(key, meta: true, shift: shift): run,
  };

  /// The mode and the status are the requests'; a change to either redraws
  /// the window, as a change of mode must.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([_requests, widget.labs.offered]),
        builder: (context, _) => _window(_view.screen(_screenKeys)),
      ),
    );
  }

  /// The top bar, the status, and under them [screen] — a mode's own — or
  /// the columns over the workspace.
  Widget _window(Widget? screen) => Column(
    children: [
      TopBar(
        mode: _requests.mode,
        onMode: _requests.switchTo,
        offered: (mode) => mode != Mode.bughouse || widget.labs.offered.value,
        onSettings: () => unawaited(_settings()),
        // A mode with a screen of its own has no list to show or hide.
        listShown: _listShown || screen != null,
        onToggleList: _toggleList,
        actions: _actions,
        // What the entries' enabled states read, heard only while the
        // menu is open: the bar itself shows none of it.
        actionsChange: Listenable.merge([_view.changes, _editing, _tabs]),
      ),
      const Divider(height: 1),
      if (_requests.status case final status?) ErrorBar(status),
      Expanded(
        child:
            screen ??
            WorkspaceKeys(
              session: _ws.session,
              analysis: _ws.analysis,
              editing: _editing,
              tabs: _tabs,
              moves: _moves,
              extra: _windowKeys,
              leave: _leave,
              child: _columns(),
            ),
      ),
    ],
  );

  /// The columns the mode puts side by side, under one set of keys: the
  /// mode's own list, the outline when a repertoire chapter is open, and the
  /// workspace filling the rest, with a divider to drag between each pair.
  Widget _columns() {
    return MultiSplitViewTheme(
      data: paneTheme(Theme.of(context).colorScheme),
      child: MultiSplitView(controller: _panes, builder: _pane),
    );
  }

  Widget _pane(BuildContext context, Area area) => switch (area.data) {
    // The mode's list, with the `«` that hides it in its top right corner.
    _Pane.list => _view.list(ListToggle(shown: true, onPressed: _toggleList)),
    _Pane.outline => OutlinePanel(
      outline: _docs.outline,
      library: _docs.library,
      session: _ws.session,
      onOpen: (ref) => unawaited(_requests.open(ref)),
    ),
    _ => WorkspaceView(
      workspace: _ws,
      tabs: _tabs,
      editing: _editing,
      moves: _moves,
      hooks: WorkspaceHooks(
        header: _view.header,
        gameCounter: _view.gameCounter,
        moveMenu: _view.moveMenu,
        tabBody: _tabBody,
        boardClaim: _claim,
        onBoardMove: _boardMove,
        onEngineMove: _engineMove,
        onExplorerGame: (game) => unawaited(
          _requests.openExplorerGame(
            game,
            source: _ws.explorer.choice.source,
            ply: _ws.explorer.ply,
          ),
        ),
        onOpenChapter: (ref) => unawaited(_requests.readInBuilder(ref, [])),
      ),
    ),
  };
}

/// The columns of the window, left to right.
enum _Pane { list, outline, workspace }

/// Keeps the Train tab's sitting beside its controls: in the mode it was
/// started in, with the Train tab open. Anywhere else the board would go on
/// showing the lesson and taking moves for it with nothing to answer or
/// leave it by, so the sitting ends.
final class SittingInView {
  SittingInView({
    required Trainer trainer,
    required WorkspaceRequests requests,
    required bool Function() trainTabOpen,
  }) : _trainer = trainer,
       _requests = requests,
       _trainTabOpen = trainTabOpen {
    for (final owner in _owners) {
      owner.addListener(check);
    }
  }

  final Trainer _trainer;
  final WorkspaceRequests _requests;

  /// Whether the mode on screen has its Train tab open: the tabs are the
  /// shell's, one set per mode.
  final bool Function() _trainTabOpen;

  /// The mode the sitting runs in, while one does.
  Mode? _mode;

  List<Listenable> get _owners => [_trainer, _requests];

  /// Ends the sitting if it is out of view; also listens to the tabs.
  void check() {
    if (_trainer.lesson == null) {
      _mode = null;
      return;
    }
    final mode = _mode ??= _requests.mode;
    if (_requests.mode != mode || !_trainTabOpen()) _trainer.leave();
  }

  void dispose() {
    for (final owner in _owners) {
      owner.removeListener(check);
    }
  }
}

/// Keeps a puzzle on the board only while Tactics is on screen. Anywhere
/// else the board would go on judging the moves made on it, Space would
/// show its answer and the arrows walk the puzzles, with nothing on screen
/// to say so; so it is put down, and the run is kept for Tactics.
final class PuzzleInView {
  PuzzleInView({
    required PuzzleTrainer puzzles,
    required WorkspaceRequests requests,
  }) : _puzzles = puzzles,
       _requests = requests {
    for (final owner in _owners) {
      owner.addListener(check);
    }
  }

  final PuzzleTrainer _puzzles;
  final WorkspaceRequests _requests;

  List<Listenable> get _owners => [_puzzles, _requests];

  /// Puts the puzzle down if it is up out of Tactics: the mode changed, or
  /// a set game came up in another mode's document.
  void check() {
    if (_puzzles.up != null && _requests.mode != Mode.tactics) {
      _puzzles.putDown();
    }
  }

  void dispose() {
    for (final owner in _owners) {
      owner.removeListener(check);
    }
  }
}

/// The way into a search from outside the Search tab — the Actions entry
/// and Ctrl+G: the tab comes up and the search starts with the numbers it
/// last had, the Replies tab's rating and cover rule and the tab's depth.
final class SearchDoor {
  SearchDoor({
    required this.fill,
    required this.settings,
    required this.requests,
  });

  final FillGaps fill;
  final SettingsStore settings;
  final WorkspaceRequests requests;

  /// What refused the search goes in the bar. A mode without a Search tab
  /// (Tactics, My games) starts nothing: the search would run where it
  /// cannot be seen or stopped, with the engine pane paused for it.
  Future<void> search(PaneTabs<WorkspaceTab> tabs) async {
    if (!fill.canStart) return;
    if (!tabs.tabs.any((tab) => tab.id == WorkspaceTab.search)) return;
    tabs.show(WorkspaceTab.search);
    final s = settings.value;
    final refusal = await fill.start(
      FillRequest(
        elo: s.opponentElo,
        depthPlies: fill.depth,
        onceIn: s.coverOnceIn,
      ),
    );
    if (refusal != null) requests.say(refusal);
  }
}
