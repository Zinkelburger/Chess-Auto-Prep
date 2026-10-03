import '../features/pgn_viewer/export_dialog.dart';
import '../features/tournaments/tournament_run.dart';
import '../features/databases/database_library.dart';
import 'dart:async';

import 'package:flutter/gestures.dart'
    show kBackMouseButton, kForwardMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../features/books/books_screen.dart' show newBook;
import '../features/library/outline_panel.dart';
import '../features/library/pgn_drop_region.dart';
import '../features/settings/setting_rows.dart';
import '../features/settings/settings_dialog.dart';
import '../features/tactics/my_games_block.dart';
import '../features/trainer/train_pane.dart';
import '../features/trainer/trainer.dart';
import '../features/trainer/training_outline.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../ui/choice_dialog.dart';
import '../ui/confirm_dialog.dart';
import '../ui/status_bar.dart';
import '../ui/listening_state.dart';
import '../ui/move_notation.dart';
import '../ui/pane_tabs.dart';
import '../ui/navigation_pages.dart';
import '../ui/theme.dart';
import '../workspace/board_claim.dart';
import '../workspace/engine_jobs.dart';
import '../workspace/document_actions.dart';
import '../workspace/book_chip.dart';
import '../workspace/copy_name_dialog.dart';
import '../storage/finds_store.dart';
import '../workspace/finds_panel.dart';
import '../workspace/move_field.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_keys.dart';
import '../workspace/workspace_tabs.dart';
import '../workspace/workspace_view.dart';
import 'full_screen.dart';
import 'layout_memory.dart';
import 'search_door.dart';
import 'mode_view.dart';
import 'mode.dart';
import 'training_visibility.dart';
import 'player_wiring.dart';
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
  /// Whether the edit strip is open. The strip's own Done closes it.
  final _editing = ValueNotifier(false);

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
    tournaments: widget.tournaments,
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

  void _resetLayout() {
    _layoutMemory.reset();
    _navigationPage = 1;
    _list.size = listColumnWidth;
    _playerList.size = playerColumnWidth;
    _outline.size = outlineColumnWidth;
    _listShown = true;
    _arrange();
    setState(() {});
  }

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
    }
    _ws.inspection?.hide();
    _shown = mode;
    _selectLayout();
    if (mode == Mode.trainer && _train.lines.lesson == null) {
      _train.lines.selection.enter(_ws.session.source);
    } else if (mode == Mode.repertoires && _train.lines.lesson == null) {
      _train.lines.selection.followDocument();
    }
    _views[mode]!.entered();
    _innerTabChanged();
    _outlineShown = _wantsOutline;
    _arrange();
  }

  Mode? _jobMode;
  EngineJobKind? _jobKind;

  void _jobChanged() {
    final kind = _ws.jobs?.activeKind;
    if (kind != _jobKind) {
      _jobKind = kind;
      _jobMode = kind == null ? null : _requests.mode;
    }
    if (mounted) setState(() {});
  }

  void _showJob() {
    final kind = _ws.jobs?.activeKind;
    if (kind == null) return;
    if (kind == EngineJobKind.tournament) {
      _requests.switchTo(Mode.engineTournament);
      final run = widget.tournaments;
      final active = run?.history
          .where((t) => t.id == run.activeId)
          .firstOrNull;
      if (active != null) run!.select(active);
      return;
    }
    final tab = switch (kind) {
      EngineJobKind.search || EngineJobKind.makingLines => WorkspaceTab.search,
      EngineJobKind.audit => WorkspaceTab.audit,
      EngineJobKind.solitaire => WorkspaceTab.solitaire,
      _ => WorkspaceTab.review,
    };
    var mode = _jobMode ?? Mode.repertoires;
    if (!_views[mode]!.layout.pane(0).tabs.any((t) => t.id == tab)) {
      mode = Mode.repertoires;
    }
    _requests.switchTo(mode);
    _views[mode]!.layout.reveal(tab);
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
    if (!shown && tabs.selected == WorkspaceTab.analysis)
      tabs.show(WorkspaceTab.moves);
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

  /// The columns and their widths. The user drags the dividers; the list
  /// column goes when hidden and the outline column comes and goes with the
  /// chapter, and the widths of the others stay what the user made them.
  /// The areas are the same three objects for the life of the window: the
  /// split view keys each pane by its area, and a pane rebuilt from a new
  /// area loses what it had open.
  final _panes = MultiSplitViewController();
  final _list = Area(
    data: _Pane.list,
    size: listColumnWidth,
    min: paneMinWidth,
  );
  final _playerList = Area(
    data: _Pane.list,
    size: playerColumnWidth,
    min: playerColumnWidth,
  );
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
  bool _compactNavigation = false;
  int _navigationPage = 1;
  final _listContentKey = GlobalKey();
  final _outlineContentKey = GlobalKey();
  bool _outlineShown = false;
  bool _listShown = true;

  /// Whether the list column shows the Positions the searches found in
  /// place of the mode's own list. One switch for every mode: the finds
  /// are the same wherever they are looked at.
  bool _positionsShown = false;

  WorkspaceRequests get _requests => widget.requests;
  Workspace get _ws => widget.workspace;
  DocumentModes get _docs => widget.documents;
  TrainingModes get _train => widget.training;

  @override
  void initState() {
    super.initState();
    _selectLayout();
    _outlineShown = _wantsOutline;
    _arrange();
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
    _requests.addListener(_modeMayHaveChanged);
    _ws.inspection?.addListener(_analysisChanged);
    _ws.jobs?.addListener(_jobChanged);
  }

  @override
  void dispose() {
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
    _panes.dispose();
    super.dispose();
  }

  void _arrange() => _panes.areas = [
    if (_listShown) _requests.mode == Mode.playerAnalysis ? _playerList : _list,
    if (_outlineShown && !_compactNavigation) _outline,
    _workspace,
  ];

  /// The outline is a repertoire chapter's lines, so it is there only when
  /// a chapter that is a whole file is open. A study chapter is one game of
  /// its file, its chapters are already in its own left column, and the line
  /// operations do not mean the same thing there — so it has no outline,
  /// whichever mode the user switches to. Hide it during a lesson too: its
  /// line previews would reveal the moves the user is being asked to recall.
  bool get _wantsOutline =>
      (_requests.mode == Mode.repertoires) &&
      _ws.session.source != null &&
      _ws.session.game == null &&
      _train.lines.board.value == null;

  @override
  Listenable listenableOf(Shell widget) => Listenable.merge([
    widget.workspace.session,
    widget.training.lines.board,
    widget.training.lines.selection,
  ]);

  /// Puts the outline column in or takes it out when the open chapter
  /// changes what is wanted. The other two panes are left alone, so the
  /// list keeps its width and whatever it has open.
  @override
  void changed() {
    _selectLayout();
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
  /// position, in the builder when it asked for it, and the Moves tab up
  /// unless only the board was to move.
  Future<void> _readLine(LineToRead line) async {
    final result = line.place == ReadIn.builder
        ? await _requests.readInBuilder(line.ref, line.sans, game: line.game)
        : await _requests.openAt(line.ref, line.sans, game: line.game);
    if (!mounted || result is! RequestDone) return;
    if (line.place != ReadIn.board) _view.show(WorkspaceTab.moves);
  }

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
              ? () => unawaited(_studyLesson())
              : null,
          onImport: _requests.mode == Mode.study
              ? null
              : () => unawaited(_importTrainingCourse()),
          onSettings: () => unawaited(
            showSettingsDialog(
              context,
              store: _ws.settings,
              groups: () => widget
                  .settingRows()
                  .where((g) => g.name == 'Training')
                  .toList(),
            ),
          ),
          moves: _moves,
          onRead: (line) => unawaited(_readLine(line)),
          offerBuilder: _view.offersBuilder,
          bookChip: BookChip(books: _ws.books, onEdit: _requests.editBooks),
        ),
        _ => null,
      };

  Future<void> _importTrainingCourse() async {
    final result = await _requests.importFile();
    if (!mounted || result is! RequestDone) return;
    if (_requests.mode == Mode.trainer) {
      final source = _ws.session.source;
      final selection = _train.lines.selection;
      final folder = selection.repertoires
          .where((r) => r.chapters.any((c) => c.path == source?.path))
          .firstOrNull;
      if (folder != null) selection.choose(folder);
    } else {
      _train.lines.setScope(TrainScope.chapter);
    }
    _view.show(WorkspaceTab.train);
  }

  Future<void> _studyLesson() async {
    final trainer = _train.lines;
    final lesson = trainer.lesson;
    if (lesson == null || lesson.suspended) return;
    final line = lesson.line;
    final shown = lesson.drill.shown;
    trainer.suspend();
    final result = await _requests.openLine(
      root: line.start,
      sans: line.moves.map((m) => m.san).toList(),
      ply: shown,
      side: line.side,
    );
    if (!mounted || trainer.lesson != lesson) return;
    if (result is! RequestDone) {
      trainer.resume();
      return;
    }
    if (!_view.layout.isOpen(WorkspaceTab.analysis))
      _view.layout.reveal(WorkspaceTab.analysis);
    if (_requests.mode == Mode.trainer) unawaited(_ws.analysis.enable());
  }

  /// Space shows the answer while a puzzle is on the board; otherwise it
  /// is the mode's: the viewer's autoplay.
  void _space() {
    if (_inspecting) return;
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
    if (_inspecting) _tabs.show(WorkspaceTab.moves);
    if (_listShown &&
        _positionsShown &&
        (!_compactNavigation || !_outlineShown || _navigationPage == 0)) {
      if (_ws.finds.step(by) case final next?) _openFind(next);
      return;
    }
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

  /// The Positions in the list column, or the mode's own list back; the
  /// column comes out if it was hidden.
  void _togglePositions() {
    if (!mounted) return;
    setState(() {
      _positionsShown = !_positionsShown || !_listShown;
      _navigationPage = 0;
      _listShown = true;
    });
    _arrange();
  }

  /// A find's line on an analysis board at its position.
  void _openFind(KeptFind kept) {
    _ws.finds.select(kept.id);
    unawaited(
      _requests.openLine(
        root: kept.rootFen,
        sans: kept.find.sans,
        ply: kept.find.ply,
        side: kept.side,
      ),
    );
  }

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

  Future<void> _analyze() async {
    _train.puzzles.inspectAlternative();
    _docs.autoplay.stop();
    _tabs.add(WorkspaceTab.analysis.tab);
  }

  Future<void> _paste({bool positionOnly = false}) async {
    if (!_inspecting) {
      await (positionOnly ? _requests.pasteFen() : _requests.paste());
      return;
    }
    final source = _ws.session.source;
    final game = _ws.session.game;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted ||
        !_inspecting ||
        source != _ws.session.source ||
        game != _ws.session.game)
      return;
    if (text == null || text.trim().isEmpty) {
      _requests.say('Nothing to paste: copy a PGN or FEN first.');
      return;
    }
    _requests.say(
      await _ws.inspection!.paste(text, positionOnly: positionOnly),
    );
  }

  Future<void> _saveCopy() async {
    final name = await showCopyNameDialog(context);
    if (name == null || !mounted) return;
    // A file this app may not write cannot have a copy beside it either.
    final result = await _ws.session.saveCopy(
      name,
      into: _ws.session.readOnly == null ? null : _docs.viewer.collections,
    );
    if (!mounted) return;
    sayCopy(_requests.say, result);
  }

  void _saveHeld() => unawaited(
    saveHeld(
      context,
      session: _ws.session,
      requests: _requests,
      collections: _docs.viewer.collections,
    ),
  );

  /// Everything the Actions menu offers now, in the mode on screen.
  List<AppAction> _actions() => [
    ..._modeActions(),
    AppAction('Reset workspace layout', _resetLayout, group: 'Layout'),
    AppAction(
      'Widen board',
      () => _view.layout.resizeBoard(_view.layout.boardFraction + 0.05),
      group: 'Layout',
    ),
    AppAction(
      'Widen reading area',
      () => _view.layout.resizeBoard(_view.layout.boardFraction - 0.05),
      group: 'Layout',
    ),
    if (_view.layout.count > 1) ...[
      AppAction(
        'Give this pane more room',
        () => _view.layout.resizeActive(0.05),
        group: 'Layout',
      ),
      AppAction(
        'Give this pane less room',
        () => _view.layout.resizeActive(-0.05),
        group: 'Layout',
      ),
    ],
    if (_view is! ViewerView)
      AppAction(
        _listShown && _positionsShown ? 'Back to the list' : 'Positions',
        _togglePositions,
        shortcut: AppKey.positions.label,
        group: 'Panels',
      ),
    if (_view is! ViewerView)
      AppAction(
        widget.fullScreen.on ? 'Leave full screen' : 'Full screen',
        widget.fullScreen.toggle,
        shortcut: AppKey.fullScreen.label,
        group: 'Window',
      ),
  ];

  List<AppAction> _modeActions() => [
    if (!_inspecting) ..._view.layout.actions,
    ..._documentModeActions(),
  ];

  List<AppAction> _documentModeActions() => _inspecting
      ? [
          ...documentActions(
            session: _boardWorkspace.session,
            analysis: _boardWorkspace.analysis,
            editing: _editing,
            onSaveCopy: () {},
          ),
          AppAction(
            'Paste PGN or FEN',
            () => unawaited(_paste()),
            shortcut: AppKey.paste.label,
            group: 'Document',
          ),
          ...tabActions(_tabs),
        ]
      : _view.actions((
          editing: _editing,
          board: () => boardActions(
            context,
            session: _ws.session,
            requests: _requests,
            library: _docs.library,
            onAnalyze: _view.offersNewAnalysis
                ? () => unawaited(_analyze())
                : null,
          ),
          dialogs: (
            saveCopy: () => unawaited(_saveCopy()),
            saveHeld: _saveHeld,
            exportPgn: () => unawaited(
              exportViewerPgn(context, _docs.viewer, _requests.say),
            ),
            search: () => unawaited(_search.search(_view.layout)),
            accounts: () => unawaited(editAccounts(context, _train.myGames)),
            newBook: () =>
                unawaited(newBook(context, _ws.books, say: _requests.say)),
          ),
        ));

  /// The same actions, typed for: a searchable list that the enter key
  /// takes the one match of.
  Future<void> _palette() async {
    final actions = [
      for (final mode in Mode.values)
        if (mode != Mode.bughouse || widget.labs.offered.value)
          AppAction('Go to ${mode.label}', () => _requests.switchTo(mode)),
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
    // ← takes back a move made past the file on the explorer Book's free board
    // before it steps back in the file.
    if (!_inspecting) ...AppKey.back.bind(_ws.tree.back),
    ..._screenKeys,
    ...AppKey.toggleList.bind(_toggleList),
    ...AppKey.positions.bind(_togglePositions),
    ...AppKey.openFile.bind(() => unawaited(_requests.openPgnFile())),
    ...AppKey.paste.bind(() => unawaited(_paste())),
    ...AppKey.pastePosition.bind(() => unawaited(_paste(positionOnly: true))),
    ...AppKey.analysisBoard.bind(() => unawaited(_analyze())),
    ...AppKey.search.bind(() => unawaited(_search.search(_view.layout))),
    ...AppKey.play.bind(_space),
    ...AppKey.nextGame.bind(() => _walk(1)),
    ...AppKey.previousGame.bind(() => _walk(-1)),
  };

  /// The window's keys a mode with a screen of its own keeps: the settings,
  /// the actions typed for, full screen, and Alt+← and Alt+→ back to where
  /// the last jump came from and forward again. The rest are the
  /// workspace's.
  Map<ShortcutActivator, VoidCallback> get _screenKeys => {
    ...AppKey.fullScreen.bind(widget.fullScreen.toggle),
    ...AppKey.settings.bind(() => unawaited(_settings())),
    ...AppKey.actions.bind(() => unawaited(_palette())),
    ...AppKey.historyBack.bind(_back),
    ...AppKey.historyForward.bind(_forward),
  };

  void _back() => unawaited(_requests.back());
  void _forward() => unawaited(_requests.forward());

  /// The mouse's own back and forward buttons do what Alt+← and Alt+→ do.
  void _mouseButton(PointerDownEvent event) {
    if (event.buttons & kBackMouseButton != 0) _back();
    if (event.buttons & kForwardMouseButton != 0) _forward();
  }

  /// The mode and the status are the requests'; a change to either redraws
  /// the window, as a change of mode must.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        onPointerDown: _mouseButton,
        child: StatusScope(
          say: _requests.say,
          child: ListenableBuilder(
            listenable: Listenable.merge([_requests, widget.labs.offered]),
            builder: (context, _) => _requests.mode == Mode.repertoires
                ? PgnDropRegion(
                    library: _docs.library,
                    onOpen: (ref) => unawaited(_requests.open(ref)),
                    child: _window(_view.screen(_screenKeys)),
                  )
                : _window(_view.screen(_screenKeys)),
          ),
        ),
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
        activity: _ws.jobs?.activeKind?.label,
        onActivity: _showJob,
        backTo: _requests.backTo?.label,
        forwardTo: _requests.forwardTo?.label,
        onBack: _back,
        onForward: _forward,
        offered: (mode) => mode != Mode.bughouse || widget.labs.offered.value,
        onSettings: () => unawaited(_settings()),
        // A mode with a screen of its own has no list to show or hide.
        listShown: _listShown || screen != null,
        onToggleList: _toggleList,
        actions: _actions,
        // What the entries' enabled states read, heard only while the
        // menu is open: the bar itself shows none of it.
        actionsChange: Listenable.merge([
          _view.changes,
          _editing,
          _view.layout,
        ]),
      ),
      const Divider(height: 1),
      if (_requests.status case final status?)
        StatusBar(
          displaySan(context, status),
          action: _requests.statusAction,
          problem: _requests.statusIsProblem,
          onClose: () => _requests.say(null),
        ),
      Expanded(
        child:
            screen ??
            WorkspaceKeys(
              session: _boardWorkspace.session,
              analysis: _boardWorkspace.analysis,
              editing: _editing,
              tabs: _tabs,
              moves: _moves,
              extra: _windowKeys,
              leave: _leave,
              save: _inspecting ? null : _saveHeld,
              child: Column(
                children: [
                  PaneTabStrip(
                    tabs: _requests.documents.tabs,
                    onSelect: (id) => unawaited(_requests.documents.select(id)),
                    onClose: (id) => unawaited(_requests.documents.close(id)),
                    onAdd: () => unawaited(_requests.newEmptyAnalysis()),
                  ),
                  Expanded(child: _columns()),
                ],
              ),
            ),
      ),
    ],
  );

  /// The columns the mode puts side by side, under one set of keys: the
  /// mode's own list, the outline when a repertoire chapter is open, and the
  /// workspace filling the rest, with a divider to drag between each pair.
  Widget _columns() => LayoutBuilder(
    builder: (context, room) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final compact = room.maxWidth < navigationSideBySideMinWidth * scale;
      if (compact != _compactNavigation) {
        _compactNavigation = compact;
        _arrange();
      }
      return MultiSplitViewTheme(
        data: paneTheme(Theme.of(context).colorScheme),
        child: MultiSplitView(controller: _panes, builder: _pane),
      );
    },
  );

  Widget _navigationList(Widget trailing) => KeyedSubtree(
    key: _listContentKey,
    child: _positionsShown
        ? FindsPanel(
            finds: _ws.finds,
            onOpen: _openFind,
            onTrain: _trainFind,
            trailing: trailing,
          )
        : _requests.mode == Mode.trainer
        ? TrainingOutline(
            trainer: _train.lines,
            trailing: trailing,
            onRead: (line) => unawaited(_readLine(line)),
            onImport: () => unawaited(_importTrainingCourse()),
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
    _Pane.list =>
      _compactNavigation && _outlineShown
          ? NavigationPages(
              list: _navigationList(const SizedBox.shrink()),
              outline: _navigationOutline(),
              trailing: ListToggle(shown: true, onPressed: _toggleList),
              listLabel: _positionsShown ? 'Positions' : 'Repertoires',
              selected: _navigationPage,
              onSelected: (page) => setState(() => _navigationPage = page),
            )
          : _navigationList(ListToggle(shown: true, onPressed: _toggleList)),
    _Pane.outline => _navigationOutline(),
    _ => WorkspaceView(
      workspace: _boardWorkspace,
      tabs: _tabs,
      layout: _inspecting ? null : _view.layout,
      editing: _editing,
      moves: _moves,
      hooks: WorkspaceHooks(
        builder: _view is RepertoiresView,
        onAnnotate: !_inspecting && _view is StudyView
            ? () => _editing.value = true
            : null,
        noteEditing: _view is RepertoiresView || _view is ViewerView,
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
            ? () => unawaited(_studyLesson())
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
        // The chapter a book move was found in: in the builder, at the
        // position the move leads to.
        onOpenPlace: (place) =>
            unawaited(_requests.readInBuilder(place.ref, place.sans)),
        onEditBooks: _requests.editBooks,
      ),
    ),
  };
}

/// The columns of the window, left to right.
enum _Pane { list, outline, workspace }
