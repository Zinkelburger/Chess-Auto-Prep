import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../features/library/outline_panel.dart';
import '../features/my_games/book_pane.dart';
import '../features/my_games/game_book.dart';
import '../features/my_games/my_games_panel.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/pgn_viewer/pgn_viewer_panel.dart';
import '../features/study/quiz_menu.dart';
import '../features/study/studies.dart';
import '../features/settings/setting_rows.dart';
import '../features/settings/settings_dialog.dart';
import '../features/study/study_panel.dart';
import '../chess/tactics/puzzle.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/my_games_block.dart';
import '../features/tactics/puzzle_pane.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/tactics_panel.dart';
import '../features/tactics/tactics_set.dart';
import '../features/trainer/train_pane.dart';
import '../features/trainer/trainer.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/error_bar.dart';
import '../ui/listening_state.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/board_claim.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/repertoire_tree.dart';
import '../workspace/tree_pane.dart';
import '../workspace/explorer.dart';
import '../workspace/game_fetcher.dart';
import '../workspace/gap_hunt.dart';
import '../workspace/fill_dialog.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/replies.dart';
import '../workspace/workspace_keys.dart';
import '../workspace/workspace_tabs.dart';
import '../workspace/workspace_view.dart';
import 'mode.dart';
import 'mode_actions.dart';
import 'my_games_doors.dart';
import 'sitting_in_view.dart';
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
    required this.library,
    required this.studies,
    required this.viewer,
    required this.outline,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.replies,
    required this.gaps,
    required this.explorer,
    required this.tree,
    required this.games,
    required this.fill,
    required this.tactics,
    required this.lineTrainer,
    required this.trainer,
    required this.myGames,
    required this.book,
    required this.settings,
    required this.settingRows,
    required this.settingsAlso,
  });

  final WorkspaceRequests requests;
  final Library library;
  final Studies studies;
  final PgnViewer viewer;
  final ChapterOutline outline;
  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;
  final Replies replies;
  final GapHunt gaps;
  final Explorer explorer;

  /// The user's own repertoires, looked up by position: the Tree tab.
  final RepertoireTree tree;
  final GameFetcher games;
  final FillGaps fill;
  final TacticsSet tactics;
  final PuzzleTrainer trainer;

  /// The usernames and the review that mines their games into the set.
  final MyGames myGames;

  /// The user's games read against their repertoires: My games.
  final GameBook book;

  /// The Train tab's owner: the repertoire's lines and the sitting.
  final Trainer lineTrainer;
  final SettingsStore settings;

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

  /// Who holds the board: a lesson first, then the Tree tab's free board.
  late final _claim = FirstClaim([widget.lineTrainer.board, widget.tree.board]);

  /// The reading card's tabs of each mode: which are open and which is up.
  /// Each mode starts with its own — the builder its four, Tactics the
  /// puzzle and its game — and keeps what the user did to them while the
  /// window lasts, as the old viewer's did.
  final _tabsByMode = <Mode, PaneTabs<WorkspaceTab>>{};

  PaneTabs<WorkspaceTab> get _tabs =>
      _tabsByMode[_requests.mode] ??= switch (_requests.mode) {
        Mode.repertoires => newWorkspaceTabs(),
        Mode.pgnViewer || Mode.study => readingTabs(),
        Mode.tactics => puzzleTabs(),
        Mode.myGames => bookTabs(),
      }..addListener(_sitting.check);

  late final _myGames = MyGamesDoors(
    requests: _requests,
    session: widget.session,
    book: widget.book,
  );

  late final _modeActions = ModeActions(
    requests: _requests,
    session: widget.session,
    saver: widget.saver,
    analysis: widget.analysis,
    gaps: widget.gaps,
    fill: widget.fill,
    viewer: widget.viewer,
    trainer: widget.trainer,
    myGames: widget.myGames,
  );

  late final _sitting = SittingInView(
    trainer: widget.lineTrainer,
    requests: _requests,
    trainTabOpen: () => _tabs.open.contains(WorkspaceTab.train),
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

  @override
  void initState() {
    super.initState();
    _outlineShown = _wantsOutline;
    _arrange();
    _sitting.check();
  }

  @override
  void dispose() {
    _sitting.dispose();
    _editing.dispose();
    _claim.dispose();
    for (final tabs in _tabsByMode.values) {
      tabs.dispose();
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
      widget.session.source != null && widget.session.game == null;

  @override
  Listenable listenableOf(Shell widget) => widget.session;

  /// Puts the outline column in or takes it out when the open chapter
  /// changes what is wanted. The other two panes are left alone, so the
  /// list keeps its width and whatever it has open.
  @override
  void changed() {
    if (_wantsOutline == _outlineShown) return;
    _outlineShown = _wantsOutline;
    _arrange();
  }

  /// The three knobs, then the run; what refused it goes in the bar.
  Future<void> _fill() async {
    final s = widget.settings.value;
    final request = await showFillDialog(
      context,
      elo: s.opponentElo,
      onceIn: s.coverOnceIn,
    );
    if (request == null || !mounted) return;
    final refusal = await widget.fill.start(request);
    if (refusal != null && mounted) _requests.say(refusal);
  }

  /// Starts a sitting, from [first] when the list asked for one, with the
  /// Puzzle tab up.
  void _play({Puzzle? first}) {
    if (!mounted) return;
    _tabs.show(WorkspaceTab.puzzle);
    unawaited(
      first == null ? widget.trainer.start() : widget.trainer.show(first),
    );
  }

  /// Tactics starts with the engine off: it is for solving, and the engine
  /// comes back with Analyze or E once an answer is on view.
  void _switchTo(Mode mode) {
    _requests.switchTo(mode);
    if (mode == Mode.tactics && widget.analysis.enabled) {
      unawaited(widget.analysis.disable());
    }
  }

  /// The solved puzzle's game with the engine on: the Game tab, not
  /// another mode.
  void _analyze() {
    if (!mounted) return;
    _tabs.show(WorkspaceTab.moves);
    unawaited(widget.analysis.enable());
  }

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
      widget.tree.watching ? widget.tree.play(uci) : widget.trainer.play(uci);

  /// A clicked engine line's moves: onto the free board while the Tree tab
  /// is up, into the document otherwise.
  void _engineMove(String uci) => widget.tree.watching
      ? widget.tree.play(uci)
      : widget.session.playMove(uci);

  Widget _bookTab(BuildContext context) => BookPane(
    book: widget.book,
    session: widget.session,
    onReadBook: _myGames.readBook,
  );

  /// Whether the board has the file's game counter under it. Tactics' list
  /// is the way to another puzzle, and My games walks its own list with the
  /// arrows, not the saved file's order.
  bool get _counted =>
      _requests.mode != Mode.tactics && _requests.mode != Mode.myGames;

  Widget _treeTab(BuildContext context) => TreePane(
    session: widget.session,
    tree: widget.tree,
    // The file a move was found in: that file, in the builder, at the
    // position the move leads to.
    onOpen: (place) =>
        unawaited(_requests.readInBuilder(place.ref, place.sans)),
  );

  /// Space and ↓ are the puzzle's while one is on the board, and the
  /// document's otherwise; in My games ↑ and ↓ walk the list.
  void _space() {
    if (widget.trainer.up != null) widget.trainer.showSolution();
  }

  void _down() => _requests.mode == Mode.myGames
      ? _myGames.step(1)
      : widget.trainer.up == null
      ? widget.session.nextGame()
      : unawaited(widget.trainer.next());

  void _up() => _requests.mode == Mode.myGames
      ? _myGames.step(-1)
      : widget.trainer.up == null
      ? widget.session.previousGame()
      : unawaited(widget.trainer.previous());

  void _toggleList() {
    if (!mounted) return;
    setState(() => _listShown = !_listShown);
    _arrange();
  }

  Future<void> _saveCopy() async {
    final name = await showCopyNameDialog(
      context,
      widget.session.chapter?.name ?? 'Chapter',
    );
    if (name == null || !mounted) return;
    final result = await widget.session.saveCopy(name);
    if (!mounted) return;
    _requests.say(switch (result) {
      CopySaved(:final name) => 'Saved a copy as $name',
      CopyNameTaken() => 'That name is taken. Nothing was replaced.',
      CopyFailed(:final detail) => 'Could not save a copy: $detail',
    });
  }

  /// Everything the Actions menu offers now, in the mode on screen.
  List<AppAction> _actions() => _modeActions.now(
    tabs: _tabs,
    editing: _editing,
    dialogs: (
      saveCopy: () => unawaited(_saveCopy()),
      fill: () => unawaited(_fill()),
      accounts: () => unawaited(editAccounts(context, widget.myGames)),
    ),
  );

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
    store: widget.settings,
    groups: widget.settingRows,
    also: widget.settingsAlso,
  );

  Map<ShortcutActivator, VoidCallback> get _windowKeys => {
    // ← takes back a move made past the file on the Tree tab's free board
    // before it steps back in the file.
    const SingleActivator(LogicalKeyboardKey.arrowLeft): widget.tree.back,
    const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
        unawaited(_settings()),
    const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
        unawaited(_settings()),
    const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggleList,
    const SingleActivator(LogicalKeyboardKey.keyB, meta: true): _toggleList,
    const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
        unawaited(_requests.openPgnFile()),
    const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () =>
        unawaited(_requests.openPgnFile()),
    if (_requests.mode == Mode.repertoires) ...{
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
          unawaited(_requests.pasteRepertoire()),
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
          unawaited(_requests.pasteRepertoire()),
    },
    const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
        unawaited(_palette()),
    const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
        unawaited(_palette()),
    const SingleActivator(LogicalKeyboardKey.space): _space,
    const SingleActivator(LogicalKeyboardKey.arrowDown): _down,
    const SingleActivator(LogicalKeyboardKey.arrowUp): _up,
  };

  /// The mode's list, with the `«` that hides it in its top right corner:
  /// the pane's edge is where the toggle lives, whichever mode fills it.
  Widget _leftColumn() {
    final toggle = ListToggle(shown: true, onPressed: _toggleList);
    return switch (_requests.mode) {
      Mode.repertoires => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => LibraryPanel(
          library: widget.library,
          selected: widget.session.source,
          onOpen: (ref) => unawaited(_requests.open(ref)),
          trailing: toggle,
        ),
      ),
      Mode.study => StudyPanel(
        studies: widget.studies,
        session: widget.session,
        onOpen: (study, chapter) =>
            unawaited(_requests.open(study, game: chapter)),
        trailing: toggle,
      ),
      Mode.pgnViewer => PgnViewerPanel(
        viewer: widget.viewer,
        onOpen: (file) => unawaited(_requests.openFile(file)),
        onBrowse: () => unawaited(_requests.browse()),
        trailing: toggle,
      ),
      Mode.tactics => TacticsPanel(
        set: widget.tactics,
        trainer: widget.trainer,
        myGames: widget.myGames,
        onPlay: _play,
        trailing: toggle,
      ),
      Mode.myGames => MyGamesPanel(
        book: widget.book,
        session: widget.session,
        accounts: MyGamesBlock(games: widget.myGames),
        onOpen: _myGames.open,
        trailing: toggle,
      ),
    };
  }

  /// The mode and the status are the requests'; a change to either redraws
  /// the window, as a change of mode must.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _requests,
        builder: (context, _) => Column(
          children: [
            TopBar(
              mode: _requests.mode,
              onMode: _switchTo,
              onSettings: () => unawaited(_settings()),
              listShown: _listShown,
              onToggleList: _toggleList,
              actions: _actions,
              // What the entries' enabled states read, heard only while the
              // menu is open: the bar itself shows none of it.
              actionsChange: Listenable.merge([
                widget.session,
                widget.saver,
                widget.analysis,
                widget.gaps,
                widget.fill,
                widget.viewer,
                widget.trainer,
                widget.myGames,
                widget.book,
                _editing,
                _tabs,
              ]),
            ),
            const Divider(height: 1),
            if (_requests.status case final status?) ErrorBar(status),
            Expanded(
              child: WorkspaceKeys(
                session: widget.session,
                analysis: widget.analysis,
                editing: _editing,
                tabs: _tabs,
                extra: _windowKeys,
                child: _columns(),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
    _Pane.list => _leftColumn(),
    _Pane.outline => OutlinePanel(
      outline: widget.outline,
      library: widget.library,
      session: widget.session,
      onOpen: (ref) => unawaited(_requests.open(ref)),
    ),
    _ => WorkspaceView(
      session: widget.session,
      saver: widget.saver,
      analysis: widget.analysis,
      replies: widget.replies,
      gaps: widget.gaps,
      explorer: widget.explorer,
      games: widget.games,
      fill: widget.fill,
      tabs: _tabs,
      editing: _editing,
      settings: widget.settings,
      moveMenu: _requests.mode == Mode.study
          ? (path) => quizMenuItems(widget.session, path)
          : null,
      onBoardMove: _boardMove,
      puzzle: PuzzlePane(trainer: widget.trainer, onAnalyze: _analyze),
      onExplorerGame: (game) => unawaited(
        _requests.openExplorerGame(
          game,
          source: widget.explorer.choice.source,
          ply: widget.explorer.ply,
        ),
      ),
      header: _requests.mode != Mode.tactics,
      gameCounter: _counted,
      boardClaim: _claim,
      onEngineMove: _engineMove,
      treeTab: _treeTab,
      bookTab: _bookTab,
      trainTab: (_) => TrainPane(
        trainer: widget.lineTrainer,
        onRead: (line) => unawaited(_readLine(line)),
        offerBuilder: _requests.mode != Mode.repertoires,
      ),
    ),
  };
}

/// The columns of the window, left to right.
enum _Pane { list, outline, workspace }
