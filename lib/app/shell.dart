import 'dart:async';

import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../features/databases/database_library.dart';
import '../features/library/outline_panel.dart';
import '../features/library/pgn_drop_region.dart';
import '../features/settings/setting_rows.dart';
import '../features/tournaments/tournament_run.dart';
import '../features/trainer/train_pane.dart';
import '../features/trainer/training_outline.dart';
import '../ui/confirm_dialog.dart';
import '../ui/status_bar.dart';
import '../ui/listening_state.dart';
import '../ui/move_notation.dart';
import '../ui/pane_tabs.dart';
import '../ui/navigation_pages.dart';
import '../ui/theme.dart';
import '../storage/finds_store.dart';
import '../workspace/board/board_claim.dart';
import '../workspace/book/book_chip.dart';
import '../workspace/search/finds_panel.dart';
import '../workspace/board/move_field.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_keys.dart';
import '../workspace/workspace_tabs.dart';
import '../workspace/workspace_view.dart';
import '../workspace/workspace_hooks.dart';
import 'board_doors.dart';
import 'document_views.dart';
import 'full_screen.dart';
import 'job_door.dart';
import 'layout_memory.dart';
import 'search_door.dart';
import 'mode_view.dart';
import 'mode.dart';
import 'training_visibility.dart';
import 'player_wiring.dart';
import 'top_bar.dart';
import 'train_doors.dart';
import 'window_actions.dart';
import 'window_columns.dart';
import 'window_keys.dart';
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
    required this.players,
    required this.databases,
    this.tournaments,
    required this.fullScreen,
    required this.settingRows,
    required this.settingsAlso,
    this.onExplorerLogin,
    this.onDownloadTwic,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;
  final DocumentModes documents;
  final TrainingModes training;
  final LabModes labs;
  final PlayerModes players;
  final DatabaseLibrary databases;
  final TournamentRun? tournaments;

  /// Whether the window fills the screen: F11, Esc and the Actions menu.
  final FullScreen fullScreen;

  /// The settings page's rows, as the app wires them, and the one owner
  /// besides the store they are built from: the Lichess account.
  final List<SettingGroup> Function() settingRows;
  final Listenable settingsAlso;
  final Future<bool> Function(BuildContext)? onExplorerLogin;
  final Future<bool> Function(BuildContext)? onDownloadTwic;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with ListeningState<Shell> {
  /// Whether the edit strip is open: `Read | Edit` in the viewer and
  /// Study, Ctrl+E and the strip's own Done elsewhere. Each mode keeps its
  /// own, in [_editingIn] while another is on screen.
  final _editing = ValueNotifier(false);
  final _editingIn = <Mode, bool>{};

  /// The words and the focus of the move field under the board, which `/`
  /// and a lesson reach as well as the field.
  final _moves = MoveEntry();

  /// Who holds the board: a lesson first, then the explorer Book's free
  /// board.
  late final _claim = FirstClaim([
    _train.lines.board,
    _train.puzzles.board,
    _ws.tree.board,
  ]);

  /// Each mode's list, tabs, Actions menu and what it adds to the
  /// workspace; the window asks the one on screen.
  late final _views = modeViews(
    workspace: _ws,
    requests: _requests,
    documents: _docs,
    training: _train,
    labs: widget.labs,
    players: widget.players,
    databases: widget.databases,
    editing: _editing,
    tournaments: widget.tournaments,
    lichessLogin: widget.onExplorerLogin,
  );

  late final _layoutMemory = LayoutMemory(_ws.settings, {
    for (final entry in _views.entries) entry.key: entry.value.layout,
  });

  void _selectLayout() =>
      _layoutMemory.select(_requests.mode, switch (_requests.mode) {
        Mode.repertoires ||
        Mode.study ||
        Mode.pgnViewer => _ws.session.source?.path,
        Mode.trainer => _train.lines.selection.root,
        _ => null,
      }, _view.layout);

  ModeView get _view => _views[_requests.mode]!;

  /// The mode on screen as last seen, so the one left and the one come to
  /// can be told: the mode changes through the requests, whoever asked —
  /// the mode menu, or a list that opens its file in another mode.
  Mode? _shown;

  void _modeMayHaveChanged() {
    final mode = _requests.mode;
    if (mode == _shown) return;
    if (_shown case final left?) {
      final previous = _views[left]!;
      if (left != Mode.trainer &&
          previous.tabs.selected == WorkspaceTab.analysis) {
        previous.tabs.show(WorkspaceTab.moves);
      }
      previous.left();
      _editingIn[left] = _editing.value;
    }
    _ws.inspection?.hide();
    _shown = mode;
    _editing.value = _editingIn[mode] ?? _views[mode]!.startsEditing;
    _selectLayout();
    if (mode == Mode.trainer && _train.lines.lesson == null) {
      _train.lines.selection.enter(_ws.session.source);
    } else if (mode == Mode.repertoires && _train.lines.lesson == null) {
      _train.lines.selection.followDocument();
    }
    _views[mode]!.entered();
    _innerTabChanged();
    _columns.arrangeForMode();
  }

  /// The engine job named in the top bar, and the way back to it.
  late final _job = JobDoor(
    jobs: _ws.jobs,
    requests: _requests,
    views: _views,
    tournaments: widget.tournaments,
  );

  void _jobChanged() {
    _job.changed();
    if (mounted) setState(() {});
  }

  /// The reading card's tabs of the mode on screen.
  PaneTabs<WorkspaceTab> get _tabs => _view.tabs;

  bool get _inspecting =>
      _requests.mode != Mode.trainer &&
      _tabs.selected == WorkspaceTab.analysis &&
      (_ws.inspection?.active ?? false);
  Workspace get _boardWorkspace => _inspecting ? _ws.inspecting : _ws;

  void _innerTabChanged() {
    if (!mounted) return;
    if (_requests.mode != Mode.trainer &&
        _tabs.selected == WorkspaceTab.analysis) {
      if (!(_ws.inspection?.active ?? false)) unawaited(_showAnalysis());
    } else {
      _ws.inspection?.hide();
    }
    setState(() {});
  }

  Future<void> _showAnalysis() async {
    final tabs = _tabs;
    final shown = await _ws.inspection?.show() ?? false;
    if (!mounted) return;
    if (!shown && tabs.selected == WorkspaceTab.analysis) {
      tabs.show(WorkspaceTab.moves);
    }
    setState(() {});
  }

  void _analysisChanged() {
    if (!mounted) return;
    if (_requests.mode != Mode.trainer &&
        !(_ws.inspection?.active ?? false) &&
        _tabs.selected == WorkspaceTab.analysis) {
      _tabs.show(WorkspaceTab.moves);
    }
    setState(() {});
  }

  late final _sitting = SittingInView(
    trainer: _train.lines,
    requests: _requests,
    trainTabOpen: () => _view.layout.visible.any(
      (i) =>
          !_view.layout.isEmpty(i) &&
          _view.layout.pane(i).selected == WorkspaceTab.train,
    ),
  );
  late final _puzzle = PuzzleInView(
    puzzles: _train.puzzles,
    requests: _requests,
  );

  /// Which columns are side by side, and how wide.
  late final _columns = WindowColumns(
    requests: _requests,
    workspace: _ws,
    lesson: _train.lines.board,
  );
  final _listContentKey = GlobalKey();
  final _outlineContentKey = GlobalKey();

  /// What the Actions menu and the palette offer, and the dialogs they open.
  late final _actions = WindowActions(
    requests: _requests,
    workspace: _ws,
    documents: _docs,
    training: _train,
    labs: widget.labs,
    columns: _columns,
    layoutMemory: _layoutMemory,
    doors: _doors,
    search: _search,
    fullScreen: widget.fullScreen,
    editing: _editing,
    view: () => _view,
    inspecting: () => _inspecting,
    settingRows: widget.settingRows,
    settingsAlso: widget.settingsAlso,
  );

  /// The window's keys over the workspace's, and the mouse's buttons.
  late final _keys = WindowKeys(
    requests: _requests,
    workspace: _ws,
    puzzles: _train.puzzles,
    columns: _columns,
    doors: _doors,
    search: _search,
    actions: _actions,
    fullScreen: widget.fullScreen,
    view: () => _view,
    inspecting: () => _inspecting,
  );

  WorkspaceRequests get _requests => widget.requests;
  Workspace get _ws => widget.workspace;
  DocumentModes get _docs => widget.documents;
  TrainingModes get _train => widget.training;

  @override
  void initState() {
    super.initState();
    _selectLayout();
    _columns.arrangeForMode();
    for (final view in _views.values) {
      view.layout.addListener(_sitting.check);
      view.layout.addListener(_innerTabChanged);
    }
    _sitting.check();
    _puzzle.check();
    _shown = _requests.mode;
    if (_shown == Mode.trainer) {
      _train.lines.selection.enter(_ws.session.source);
    }
    // The mode the window opens on is entered as one switched to is: its
    // side of `Read | Edit` decides what a move on the board does.
    if (_view.editSwitch) {
      _editing.value = _view.startsEditing;
      _view.entered();
    }
    _editing.addListener(_redraw);
    _columns.addListener(_redraw);
    _requests.addListener(_modeMayHaveChanged);
    _ws.inspection?.addListener(_analysisChanged);
    _ws.jobs?.addListener(_jobChanged);
  }

  /// Reading quiets the board and editing gives it its tools back; the
  /// columns redraw what they hold.
  void _redraw() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _editing.removeListener(_redraw);
    _columns.removeListener(_redraw);
    _requests.removeListener(_modeMayHaveChanged);
    _ws.jobs?.removeListener(_jobChanged);
    _ws.inspection?.removeListener(_analysisChanged);
    _layoutMemory.dispose();
    _sitting.dispose();
    _puzzle.dispose();
    _editing.dispose();
    _moves.dispose();
    _claim.dispose();
    for (final view in _views.values) {
      view.layout.removeListener(_innerTabChanged);
      view.dispose();
    }
    _columns.dispose();
    super.dispose();
  }

  @override
  Listenable listenableOf(Shell widget) => Listenable.merge([
    widget.workspace.session,
    widget.training.lines.board,
    widget.training.lines.selection,
  ]);

  /// The open chapter decides the layout remembered for it and whether
  /// the outline column is there.
  @override
  void changed() {
    _selectLayout();
    _columns.followOutline();
  }

  late final _search = SearchDoor(
    fill: _ws.fill,
    settings: _ws.settings,
    requests: _requests,
  );

  late final _trainDoors = TrainDoors(
    requests: _requests,
    workspace: _ws,
    trainer: _train.lines,
    view: () => _view,
    mounted: () => mounted,
  );

  /// While the explorer's Book is up the board is its free board; otherwise a
  /// move on the board is the puzzle's, or the document's.
  void _boardMove(String uci) {
    if (_ws.solitaire?.play(uci) == true) return;
    _ws.tree.watching ? _ws.tree.play(uci) : _train.puzzles.play(uci);
  }

  /// A clicked engine line's moves: onto the free board while the explorer's
  /// Book is up, into the document otherwise.
  void _engineMove(String uci) =>
      _ws.tree.watching ? _ws.tree.play(uci) : _ws.session.playMove(uci);

  /// The body of a tab the workspace does not draw: the mode's own first,
  /// then the Train tab every mode that has it shares.
  Widget? _tabBody(BuildContext context, WorkspaceTab tab) =>
      _view.tab(context, tab) ??
      switch (tab) {
        WorkspaceTab.train => TrainPane(
          trainer: _train.lines,
          onStudy: _requests.mode == Mode.trainer
              ? () => unawaited(_trainDoors.studyLesson())
              : null,
          onImport: _requests.mode == Mode.study
              ? null
              : () => unawaited(_trainDoors.importCourse()),
          onSettings: () => unawaited(_actions.trainingSettings(context)),
          moves: _moves,
          onRead: (line) => unawaited(_trainDoors.readLine(line)),
          offerBuilder: _view.offersBuilder,
          bookChip: BookChip(books: _ws.books, onEdit: _requests.editBooks),
        ),
        _ => null,
      };

  /// A trap's line trained in the builder, put in the draft first when no
  /// chapter plays it yet and the user agrees.
  void _trainFind(KeptFind kept) => unawaited(
    _train.traps.train(
      kept,
      addToDraft: (draft) async =>
          mounted &&
          await confirmAction(
            context,
            title: 'Train this line',
            message: 'No chapter plays this line yet. Add it to $draft first?',
            confirm: 'Add and train',
          ),
      showTrain: () {
        if (mounted) _views[Mode.repertoires]!.show(WorkspaceTab.train);
      },
    ),
  );

  late final _doors = BoardDoors(
    requests: _requests,
    workspace: _ws,
    inspecting: () => mounted && _inspecting,
  );

  void _saveHeld() => _actions.saveHeld(context);

  /// The mode and the status are the requests'; a change to either redraws
  /// the window, as a change of mode must.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        onPointerDown: _keys.mouseButton,
        child: StatusScope(
          say: _requests.say,
          child: ListenableBuilder(
            listenable: Listenable.merge([_requests, widget.labs.offered]),
            builder: (context, _) => _requests.mode == Mode.repertoires
                ? PgnDropRegion(
                    library: _docs.library,
                    onOpen: (ref) => unawaited(_requests.open(ref)),
                    child: _modeWindow(),
                  )
                : _modeWindow(),
          ),
        ),
      ),
    );
  }

  /// The window of the mode on screen: its own screen, keeping the
  /// window's screen keys, or the workspace.
  Widget _modeWindow() =>
      _window(_doors.onScreen(_view.screen(_keys.screen(context))));

  /// The top bar with the status sentence in it, and under it [screen] — a
  /// mode's own — or the columns over the workspace.
  Widget _window(Widget? screen) => Column(
    children: [
      TopBar(
        mode: _requests.mode,
        onMode: _requests.switchTo,
        activity: _ws.jobs?.activeKind?.label,
        onActivity: _job.show,
        backTo: _requests.backTo?.label,
        forwardTo: _requests.forwardTo?.label,
        onBack: _keys.back,
        onForward: _keys.forward,
        offered: (mode) => mode != Mode.bughouse || widget.labs.offered.value,
        onSettings: () => unawaited(_actions.settings(context)),
        // A mode with a screen of its own has no list to show or hide.
        listShown: _columns.listShown || screen != null,
        onToggleList: _columns.toggleList,
        actions: () => _actions.entries(context),
        // What the entries' enabled states read, heard only while the
        // menu is open: the bar itself shows none of it.
        actionsChange: Listenable.merge([
          _view.changes,
          _editing,
          _view.layout,
        ]),
        status: switch (_requests.status) {
          final status? => StatusBar(
            displaySan(context, status),
            action: _requests.statusAction,
            problem: _requests.statusIsProblem,
            onClose: () => _requests.say(null),
          ),
          null => null,
        },
      ),
      const Divider(height: 1),
      Expanded(
        child:
            screen ??
            WorkspaceKeys(
              session: _boardWorkspace.session,
              analysis: _boardWorkspace.analysis,
              editing: _editing,
              tabs: _tabs,
              moves: _moves,
              extra: _keys.all(context),
              leave: _keys.leave,
              save: _inspecting ? null : _saveHeld,
              escapeEndsEditing: _inspecting || !_view.editSwitch,
              child: Column(
                children: [
                  PaneTabStrip(
                    tabs: _requests.documents.tabs,
                    onSelect: (id) => unawaited(_requests.documents.select(id)),
                    onClose: (id) => unawaited(_requests.documents.close(id)),
                    onAdd: () => unawaited(_requests.newEmptyAnalysis()),
                  ),
                  Expanded(child: _split()),
                ],
              ),
            ),
      ),
    ],
  );

  /// The columns the mode puts side by side, under one set of keys: the
  /// mode's own list, the outline when a repertoire chapter is open, and the
  /// workspace filling the rest, with a divider to drag between each pair.
  Widget _split() => LayoutBuilder(
    builder: (context, room) {
      _columns.fit(
        room.maxWidth,
        MediaQuery.textScalerOf(context).scale(14) / 14,
      );
      return MultiSplitViewTheme(
        data: paneTheme(Theme.of(context).colorScheme),
        child: MultiSplitView(controller: _columns.controller, builder: _pane),
      );
    },
  );

  Widget _navigationList(Widget trailing) => KeyedSubtree(
    key: _listContentKey,
    child: _columns.positionsShown
        ? FindsPanel(
            finds: _ws.finds,
            session: _ws.session,
            onOpen: _doors.openFind,
            onTrain: _trainFind,
            trailing: trailing,
          )
        : _requests.mode == Mode.trainer
        ? TrainingOutline(
            trainer: _train.lines,
            trailing: trailing,
            onRead: (line) => unawaited(_trainDoors.readLine(line)),
            onImport: () => unawaited(_trainDoors.importCourse()),
          )
        : _view.list(trailing),
  );

  Widget _navigationOutline() => OutlinePanel(
    key: _outlineContentKey,
    outline: _docs.outline,
    library: _docs.library,
    session: _ws.session,
    onOpen: (ref) => unawaited(_requests.open(ref)),
  );

  Widget _pane(BuildContext context, Area area) => switch (area.data) {
    // The mode's list or the Positions, with the `«` that hides the
    // column in its top right corner.
    WindowPane.list =>
      _columns.paged
          ? NavigationPages(
              list: _navigationList(const SizedBox.shrink()),
              outline: _navigationOutline(),
              trailing: ListToggle(shown: true, onPressed: _columns.toggleList),
              listLabel: _columns.positionsShown ? 'Positions' : 'Repertoires',
              selected: _columns.page,
              onSelected: _columns.showPage,
            )
          : _navigationList(
              ListToggle(shown: true, onPressed: _columns.toggleList),
            ),
    WindowPane.outline => _navigationOutline(),
    _ => WorkspaceView(
      workspace: _boardWorkspace,
      tabs: _tabs,
      layout: _inspecting ? null : _view.layout,
      editing: _editing,
      moves: _moves,
      hooks: WorkspaceHooks(
        builder: _view is RepertoiresView,
        onAnnotate: !_inspecting && _view.editSwitch
            ? () => _editing.value = true
            : null,
        editSwitch: !_inspecting && _view.editSwitch,
        studyTools: !_inspecting && _view.studyTools,
        noteEditing: _view is RepertoiresView,
        header: _view.header,
        underHeading: _inspecting ? null : _view.underHeading,
        quietBoard: _view.quietBoard,
        paneActions: _inspecting ? null : () => _view.paneActions(_editing),
        explorerFileBar: _inspecting ? null : _view.explorerFileBar,
        gameCounter: !_inspecting && _view.gameCounter,
        gameOrdering: _view.gameOrdering,
        moveMenu: _inspecting ? null : _view.moveMenu,
        tabBody: _tabBody,
        boardClaim: _inspecting ? null : _claim,
        lesson: _inspecting ? null : _train.lines.board,
        trainingTools: _requests.mode == Mode.trainer,
        onStudyLesson: _requests.mode == Mode.trainer
            ? () => unawaited(_trainDoors.studyLesson())
            : null,
        onBoardMove: _inspecting ? null : _boardMove,
        onEngineMove: _inspecting ? null : _engineMove,
        onSaveHeld: _inspecting ? null : _saveHeld,
        onExplorerLogin: widget.onExplorerLogin,
        onDownloadTwic: widget.onDownloadTwic,
        onExplorerGame: (game, source, ply) => unawaited(
          _requests.openExplorerGame(game, source: source, ply: ply),
        ),
        onOpenChapter: (ref) => unawaited(_requests.readInBuilder(ref, [])),
        onShowPositions: _columns.showPositions,
        // The chapter a book move was found in: in the builder, at the
        // position the move leads to.
        onOpenPlace: (place) =>
            unawaited(_requests.readInBuilder(place.ref, place.sans)),
        onEditBooks: _requests.editBooks,
      ),
    ),
  };
}
