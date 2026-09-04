/// PGN Viewer mode — browse master game collections for study.
///
/// Features: file picker, position/header-based dataset slicing, game-by-game
/// navigation with counter, auto-play with configurable delay, 1-5 star game
/// rating (persisted as [StudyRating] PGN header, auto-saved), full-game
/// Stockfish analysis with eval graph, inline engine bar, and comment editing.
///
/// The screen state is split across part files: app-bar builders in
/// `pgn_viewer_screen_app_bar.dart`, body/pane builders in
/// `pgn_viewer_screen_panes.dart`, and the generate-repertoire-from-games
/// flow in `pgn_viewer_screen_repertoire.dart`.
library;

import '../widgets/common/name_entry_dialog.dart';
import 'dart:async';
import 'dart:convert';
import 'package:dartchess/dartchess.dart' show Position;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../core/pgn_viewer_controller.dart';
import '../core/pgn/solitaire_controller.dart';
import '../features/games/services/game_deviation_service.dart';
import '../features/games/services/game_moves.dart';
import '../features/games/services/my_repertoire_settings.dart';
import '../features/games/widgets/repertoire_line_panel.dart';
import '../core/study_controller.dart';
import '../services/games_library/game_filter.dart' show dedupKeyForHeaders;
import '../services/storage/app_paths.dart';
import '../services/lichess_auth_service.dart';
import '../services/storage/storage_factory.dart';
import '../services/game_analysis_controller.dart';
import '../models/board_annotation.dart';
import '../models/solitaire_trophy.dart';
import '../services/solitaire_trophy_detector.dart';
import '../services/solitaire_trophy_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/shortcut_tooltip.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/common/confirm_dialog.dart';
import '../widgets/engine/engine_gate.dart';
import '../widgets/layout/responsive_split_layout.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/fullscreen_game_view.dart';
import '../widgets/game_analysis_tab.dart';
import '../widgets/game_nav_bar.dart';
import '../widgets/game_number_field.dart';
import '../widgets/game_search_dialog.dart';
import '../widgets/pgn/generate_repertoire_dialog.dart';
import '../widgets/study/add_to_study_flow.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/pgn/pgn_opening_tree_panel.dart';
import '../widgets/pgn/pgn_perspective_button.dart';
import '../widgets/pgn/pgn_slice_chips.dart';
import '../widgets/pgn/solitaire_status_widgets.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/pgn_slice_dialog.dart';
import '../widgets/solitaire_trophy_cabinet.dart';

part 'pgn_viewer_screen_app_bar.dart';
part 'pgn_viewer_screen_panes.dart';
part 'pgn_viewer_screen_repertoire.dart';

/// Side-panel tab indices. Game is always 0. Line is only present when
/// reviewing one of your games from the Games/tactics handoff; Analysis
/// sits at 1 otherwise. Named getters (not constants) so an `animateTo(1)`
/// cannot silently mean the wrong tab.
const int _kGameTab = 0;

class PgnViewerScreen extends StatefulWidget {
  const PgnViewerScreen({super.key});

  @override
  State<PgnViewerScreen> createState() => _PgnViewerScreenState();
}

class _PgnViewerScreenState extends State<PgnViewerScreen>
    with
        TickerProviderStateMixin,
        WindowListener,
        _RepertoireGenerationMixin,
        _AppBarBuildersMixin,
        _PaneBuildersMixin {
  @override
  late final PgnViewerController _controller;
  @override
  late final PgnViewerWidgetController _pgnWidgetController;

  /// Movetext cursor for the Line tab's book line, so arrow keys drive whichever
  /// pane is on screen instead of always the game.
  @override
  late final PgnViewerWidgetController _lineWidgetController;
  @override
  late final GameAnalysisController _analysisController;
  @override
  late TabController _tabController;
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnViewerScreen');

  @override
  bool _editMode = false;

  bool _singleGameFocusValue = false;

  @override
  bool get _singleGameFocus => _singleGameFocusValue;

  /// Line tab is only for reviewing one of your games from Games/tactics.
  @override
  bool get _lineTabVisible => _singleGameFocusValue;

  int get _lineTabIndex => _lineTabVisible ? 1 : -1;

  int get _analysisTabIndex => _lineTabVisible ? 2 : 1;

  @override
  set _singleGameFocus(bool value) {
    if (_singleGameFocusValue == value) return;
    _singleGameFocusValue = value;
    _rebuildTabController();
    if (mounted) setState(() {});
  }

  /// Whether the PGN Viewer is the app's visible mode, so that arriving here
  /// can be told from any other [AppState] change (see [_onAppStateChanged]).
  bool _isCurrentMode = false;

  /// Cached so [dispose] does not [BuildContext.read] after unmount.
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    // Game · Analysis by default. Line is added only for a Games/tactics
    // handoff (see [_lineTabVisible]).
    _tabController = TabController(length: 2, vsync: this);
    _pgnWidgetController = PgnViewerWidgetController();
    _lineWidgetController = PgnViewerWidgetController();
    _analysisController = GameAnalysisController();
    _analysisController.addListener(_onAnalysisUpdate);
    _controller = PgnViewerController(
      pgnWidgetController: _pgnWidgetController,
      analysisController: _analysisController,
      isActive: () => mounted,
      schedulePostFrame: (fn) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => fn()),
      onReclaimFocus: _reclaimFocus,
    );
    _controller.addListener(_onControllerUpdate);
    MyRepertoireSettings.instance.addListener(_onRepertoireDesignationsChanged);
    windowManager.addListener(this);
    // Leaving the Line tab hands the board back to the game: the tab you are
    // reading owns the board, so flipping between them is a comparison of the
    // same position rather than two viewers fighting over one board.
    _tabController.addListener(_onSideTabChanged);
    unawaited(_controller.loadRecentFiles());
    unawaited(_controller.loadCollections());
    unawaited(_controller.loadSolitaireSettings());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        _appState = appState;
        appState.addListener(_onAppStateChanged);
        _isCurrentMode = appState.currentMode == AppMode.pgnViewer;
        // The screen may have been created by the very mode switch that set
        // the pending file (listener not registered yet) — consume it now.
        _consumePendingViewerFile(appState);
      }
    });
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    // Trophies belong to one game's analysis; the banner and the per-move
    // markers key off its positions, so they must not survive a game switch.
    if (_detectedTrophies.isNotEmpty &&
        _controller.currentGameIndex != _trophyGameIndex) {
      _detectedTrophies = const [];
    }
    _maybeUpdateDeviation();
    setState(() {});
  }

  void _onAppStateChanged() {
    final appState = _appState;
    if (appState == null) return;
    final isCurrent = appState.currentMode == AppMode.pgnViewer;
    final arrived = isCurrent && !_isCurrentMode;
    _isCurrentMode = isCurrent;
    if (!isCurrent) return;
    if (!_consumePendingViewerFile(appState) && arrived) {
      _dropHandedOffGame();
    }
    _reclaimFocus();
  }

  /// Handoff hook: open the pending file, then optionally slice to a
  /// position ("Open Games in PGN Viewer"), jump to one game and start the
  /// review ("Review" on the Games page). Returns whether one was waiting.
  bool _consumePendingViewerFile(AppState appState) {
    final handoff = appState.takeHandoff<OpenPgnViewer>();
    if (handoff == null) return false;
    unawaited(_openFromHandoff(handoff));
    return true;
  }

  /// Entering the viewer from the mode menu asks for the viewer itself, not
  /// for the last game something else sent here: "Review" on a game card
  /// leaves the whole games cache loaded and focused on one game, and meeting
  /// that file again — instead of the start screen — reads as the viewer
  /// having opinions about what you want to look at. So a single-game handoff
  /// is dropped on the way back in; the file stays in the recent list, which
  /// is the one click back.
  ///
  /// A collection *you* opened here (browse, recent, paste, a study, a sliced
  /// player-analysis dataset) is your own choice and stays put. So does a game
  /// whose engine review is still running — you left to let it finish.
  void _dropHandedOffGame() {
    if (!_singleGameFocus || _analysisController.isAnalyzing) return;
    _closeFile();
  }

  Future<void> _openFromHandoff(OpenPgnViewer handoff) async {
    final gameId = handoff.gameId;
    // Arriving with one game named is a different job from opening a
    // collection: the app bar's slice machinery (player presets, add-filter
    // chip, filtered/total counter) is about carving a dataset up, and none of
    // it applies to "show me this game". [_singleGameFocus] takes it off the
    // bar; opening any file yourself brings it back.
    _singleGameFocus = gameId != null;

    // Fast path: the requested game lives in the file that's already open
    // (Games page → Review → breadcrumb back → Review again). Reloading
    // would re-parse the whole games cache and — worse — cancel and forget
    // an analysis that is still running, so reuse the loaded collection.
    final sameFileLoaded =
        handoff.sliceFen == null &&
        gameId != null &&
        handoff.pgnPath == _controller.filePath &&
        _controller.errorMessage == null &&
        _controller.allGames.isNotEmpty &&
        // ...and the loaded copy is still what is on disk. The review of your
        // recent games writes the scores it found back into the games cache,
        // so a collection read before a run is a collection whose games have
        // no graph — reusing it would draw a blank chart over evals that are
        // sitting in the file.
        await _loadedCopyIsCurrent(handoff.pgnPath);
    if (sameFileLoaded) {
      if (_currentGameIs(gameId)) {
        _applyHandoffTab(handoff);
        return;
      }
      if (await _goToGameById(gameId)) {
        if (!mounted) return;
        _applyHandoffTab(handoff);
        return;
      }
      // Not in the loaded copy (the cache gained games since) — fall through
      // to a full reload.
      if (!mounted) return;
    }

    await _openFileWithPositionSlice(
      handoff.pgnPath,
      handoff.sliceFen,
      // A single-game handoff must not resurrect an old slice: it can hide
      // the target game and its filtered/total counter reads as noise when
      // all you asked for was one game. Same for a file-position jump —
      // a restored slice would shift the indices it was computed against.
      restoreSavedSlice: gameId == null && handoff.gameIndex == null,
    );
    if (!mounted ||
        _controller.errorMessage != null ||
        _controller.filePath != handoff.pgnPath) {
      return;
    }
    if (gameId != null) {
      final found = await _goToGameById(gameId);
      if (!found || !mounted) return;
    } else if (handoff.gameIndex != null &&
        _controller.filteredGames.isNotEmpty) {
      _controller.goToGame(
        handoff.gameIndex!.clamp(0, _controller.filteredGames.length - 1),
      );
    }
    _applyHandoffTab(handoff);
  }

  /// Land on the tab that answers the question the handoff asked, and start the
  /// engine only when it was the engine's answer that was wanted.
  ///
  /// Solitaire hides the side-panel tabs entirely; don't fight the mode.
  void _applyHandoffTab(OpenPgnViewer handoff) {
    if (_controller.isSolitaireMode) return;
    switch (handoff.tab) {
      case PgnViewerTab.game:
        _tabController.animateTo(_kGameTab);
      case PgnViewerTab.line:
        _showLineTab();
      case PgnViewerTab.analysis:
        _tabController.animateTo(_analysisTabIndex);
    }
    if (handoff.autoAnalyze) _startAutoAnalysisForCurrentGame();
    final ply = handoff.ply;
    if (ply != null) {
      // The PGN widget takes the newly selected game on its next build and
      // parks the cursor at the start; move it after that build, not before.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.goToPly(ply);
      });
    }
  }

  /// Whether the open collection still matches its file on disk.
  ///
  /// True when the mtimes agree, and true when either is unavailable: an
  /// unreadable stat is not evidence of a change, and treating it as one would
  /// re-parse the whole games cache on every handoff.
  Future<bool> _loadedCopyIsCurrent(String path) async {
    final loadedAt = _controller.loadedFileModified;
    if (loadedAt == null) return true;
    final stat = await StorageFactory.instance.fileStat(path);
    if (stat == null) return true;
    return stat.modified == loadedAt;
  }

  /// Whether the currently displayed game is [gameId].
  bool _currentGameIs(String gameId) {
    final key = _currentGameDedupKey();
    return key != null && key == gameId;
  }

  /// Identity of the currently displayed game — the games-library
  /// [dedupKeyForHeaders], which is what a single-game handoff names.
  String? _currentGameDedupKey() {
    final games = _controller.filteredGames;
    if (games.isEmpty || _controller.currentGameIndex >= games.length) {
      return null;
    }
    return dedupKeyForHeaders(games[_controller.currentGameIndex].headers);
  }

  Future<bool> _goToGameById(String gameId) async {
    // Newest-first before locating it: this game came from the recent-games
    // list, and the games cache's file order is a download log — the game you
    // played five minutes ago sits wherever its batch landed ("Game 301 of
    // 312"). Sorted, the counter agrees with the list you clicked from, and
    // Prev/Next walk back through time instead of through fetch history.
    _controller.sortNewestFirst();
    var index = _controller.filteredGames.indexWhere(
      (g) => dedupKeyForHeaders(g.headers) == gameId,
    );
    if (index < 0) {
      // A restored slice may hide the target game — widen to the whole file.
      // (resetFilters re-applies the sort, so the order survives.)
      _controller.resetFilters();
      index = _controller.filteredGames.indexWhere(
        (g) => dedupKeyForHeaders(g.headers) == gameId,
      );
    }
    if (index < 0) return false;
    _controller.currentGameIndex = index;
    // Awaited (goToGame fires loadCurrentGame without waiting): the
    // cached-eval restore must finish before autoAnalyze decides whether an
    // engine pass is still needed.
    await _controller.loadCurrentGame();
    return true;
  }

  /// Start the engine review of the current game unless cached `[%eval]`s
  /// already cover it. Mirrors the Analysis tab's manual "Analyze Game"
  /// button, including persistence and trophy detection.
  void _startAutoAnalysisForCurrentGame() {
    if (_controller.filteredGames.isEmpty) return;
    _tabController.animateTo(_analysisTabIndex);
    if (_analysisController.isAnalyzing) return;
    if (_analysisController.evals.isNotEmpty) return;
    if (!EngineGate.ensureAvailable(context)) return;
    unawaited(
      _analysisController.analyzeGame(
        _controller.filteredGames[_controller.currentGameIndex].pgnText,
        onAnnotatedMovetext: _controller.persistMoveComments,
        onComplete: _detectTrophies,
      ),
    );
  }

  Future<void> _openFileWithPositionSlice(
    String path,
    String? sliceFen, {
    bool restoreSavedSlice = true,
  }) async {
    // When a position slice is about to be applied it supersedes any restored
    // slice, so a "Restored last slice" notice would be misleading.
    await _loadFile(
      path,
      notifySliceRestore: sliceFen == null && restoreSavedSlice,
      restoreSavedSlice: restoreSavedSlice,
    );
    // Bail if the load failed (the old file's games would still be in the
    // controller and the slice would silently target the wrong collection).
    if (!mounted ||
        _controller.errorMessage != null ||
        _controller.filePath != path ||
        _controller.allGames.isEmpty ||
        sliceFen == null) {
      return;
    }
    await _controller.recomputeAndApplyConfig(
      SliceConfig(positionInput: sliceFen),
    );
    if (!mounted) return;
    final count = _controller.filteredGames.length;
    showAppSnackBar(
      context,
      'Showing $count game${count == 1 ? '' : 's'} containing the position',
      actionLabel: 'Show All',
      onAction: () => _controller.resetFilters(),
    );
  }

  void _onAnalysisUpdate() {
    if (mounted) setState(() {});
  }

  void _onSideTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    if (_tabController.index == _lineTabIndex) {
      if (!_lineTabVisited) setState(() => _lineTabVisited = true);
      return;
    }
    final gamePosition = _gamePanePosition;
    if (gamePosition != null) _controller.onPositionChanged(gamePosition);
  }

  void _rebuildTabController() {
    final want = _lineTabVisible ? 3 : 2;
    if (_tabController.length == want) return;
    final old = _tabController;
    final oldIndex = old.index;
    final newIndex = want == 3
        ? (oldIndex >= 1 ? 2 : 0)
        : (oldIndex >= 2 ? 1 : 0);
    old.removeListener(_onSideTabChanged);
    _tabController = TabController(
      length: want,
      vsync: this,
      initialIndex: newIndex.clamp(0, want - 1),
    );
    _tabController.addListener(_onSideTabChanged);
    old.dispose();
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    windowManager.removeListener(this);
    MyRepertoireSettings.instance.removeListener(
      _onRepertoireDesignationsChanged,
    );
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    _analysisController.removeListener(_onAnalysisUpdate);
    _analysisController.dispose();
    _tabController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void onWindowLeaveFullScreen() => _controller.onWindowLeaveFullScreen();

  @override
  void onWindowEnterFullScreen() => _controller.onWindowEnterFullScreen();

  @override
  void _reclaimFocus() =>
      reclaimFocusAfterFrame(_focusNode, mounted: () => mounted);

  @override
  Future<void> _pickFile() async {
    _singleGameFocus = false;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
      initialDirectory: _controller.pickFileInitialDirectory(),
    );
    if (file == null || file.path == null) return;
    await _loadFile(file.path!);
  }

  @override
  Future<void> _pastePgn() async {
    _singleGameFocus = false;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    await _controller.loadPgnContent(data?.text ?? '');
    if (!mounted) return;
    final error = _controller.errorMessage;
    if (error != null) {
      showAppSnackBar(context, error, duration: const Duration(seconds: 4));
      return;
    }
    showAppSnackBar(
      context,
      'Loaded ${_controller.allGames.length} game(s) from clipboard',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Future<void> _loadFile(
    String path, {
    bool notifySliceRestore = true,
    bool restoreSavedSlice = true,
  }) async {
    await _controller.loadFile(path, restoreSavedSlice: restoreSavedSlice);
    if (!mounted) return;
    final error = _controller.errorMessage;
    if (error != null) {
      showAppSnackBar(context, error, duration: const Duration(seconds: 5));
      return;
    }
    if (notifySliceRestore) _showPendingSliceRestoreSnackBar();
  }

  /// "Close file": drop the collection and land back on the start screen.
  ///
  /// The screen's own per-file modes go with it — amend mode, single-game
  /// focus and the trophies found in one game are all about a game that no
  /// longer exists — and the side panel returns to the Game tab, since Line
  /// and Analysis have nothing to say about an empty viewer.
  @override
  void _closeFile() {
    _controller.closeFile();
    setState(() {
      _editMode = false;
      _singleGameFocus = false;
      _detectedTrophies = const [];
      _trophyGameIndex = -1;
    });
    if (_tabController.index != _kGameTab) _tabController.animateTo(_kGameTab);
    _reclaimFocus();
  }

  void _showPendingSliceRestoreSnackBar() {
    final info = _controller.pendingSliceRestore;
    if (info == null || !mounted) return;
    _controller.clearPendingSliceRestore();
    showAppSnackBar(
      context,
      'Restored last slice (${info.filteredCount}/${info.totalCount} games)',
      actionLabel: 'Show All',
      onAction: _controller.resetFilters,
    );
  }

  @override
  void _openSliceDialog() {
    unawaited(
      showDialog(
        context: context,
        builder: (ctx) => PgnSliceDialog(
          allGames: _controller.allGames
              .map((g) => (headers: g.headers, pgnText: g.pgnText))
              .toList(),
          currentFen: normalizeFen(_controller.currentPosition.fen),
          initialConfig: _controller.activeSliceConfig.isEmpty
              ? null
              : _controller.activeSliceConfig,
          fenIndex: _controller.fenIndex,
          presets: _controller.slicePresets,
          onApply: (indices, config) {
            _controller.applySlice(indices, config);
          },
        ),
      ).then((_) => _reclaimFocus()),
    );
  }

  /// Trophies found in the game currently loaded, shown as a banner and
  /// per-move markers in the analysis tab. Cleared whenever the game changes.
  @override
  List<SolitaireTrophy> _detectedTrophies = const [];

  /// Game index [_detectedTrophies] were found in.
  int _trophyGameIndex = -1;

  /// Where the loaded game first left the designated repertoire (Settings →
  /// My repertoires), when I played in it and a book is designated. Shown as
  /// a banner above the side-panel tabs.
  @override
  DeviationReport? _deviationReport;

  /// Identity (file + game) [_deviationReport] belongs to; also the
  /// staleness guard for the async compute.
  String? _deviationKey;

  void _maybeUpdateDeviation() {
    final games = _controller.filteredGames;
    final index = _controller.currentGameIndex;
    // Keyed by game identity, not index: applying or clearing a slice resets
    // the index to 0 with a different game there, and an index-based key
    // would keep the previous game's banner.
    final key = games.isEmpty || index >= games.length
        ? null
        : '${_controller.filePath}'
              '#${dedupKeyForHeaders(games[index].headers)}';
    if (key == _deviationKey) return;
    _deviationKey = key;
    _deviationReport = null;
    if (key == null) return;
    unawaited(_computeDeviation(key));
  }

  /// Settings → My repertoires changed: the banner may now be wrong (or
  /// newly possible) for the already-loaded game, so recompute it.
  void _onRepertoireDesignationsChanged() {
    if (!mounted) return;
    setState(() {
      _deviationKey = null;
      _deviationReport = null;
    });
    _maybeUpdateDeviation();
  }

  Future<void> _computeDeviation(String key) async {
    final games = _controller.filteredGames;
    if (games.isEmpty) return;
    final entry = games[_controller.currentGameIndex];
    final meWhite = _myColorIn(entry.headers);
    if (meWhite == null) return;
    final report = await GameDeviationService.instance.analyzeGame(
      gameSans: extractMainlineSans(entry.pgnText),
      meWhite: meWhite,
    );
    if (!mounted || key != _deviationKey) return;
    setState(() => _deviationReport = report);
  }

  /// Which side I played in a game, by matching the configured account
  /// usernames against the White/Black headers. Null when neither matches —
  /// then the game isn't mine and deviation is meaningless.
  @override
  bool? _myColorIn(Map<String, String> headers) {
    final appState = context.read<AppState>();
    final names = <String>{
      for (final name in [
        appState.chesscomUsername,
        appState.lichessUsername,
        LichessAuthService.instance.username,
      ])
        if (name != null && name.trim().isNotEmpty) name.trim().toLowerCase(),
    };
    final white = headers['White']?.trim().toLowerCase();
    final black = headers['Black']?.trim().toLowerCase();
    if (white != null && names.contains(white)) return true;
    if (black != null && names.contains(black)) return false;
    return null;
  }

  /// Open a book chapter in the Repertoire Builder — the deliberate trip to
  /// *edit* the prep, as opposed to reviewing it on the Line tab.
  @override
  void _openInBuilder(DeviationReport report) {
    context.read<AppState>().switchToBuilder(
      repertoirePath: report.chapterPath,
      moveSequence: report.pathSans,
      historyLabel: 'Repertoire: ${report.chapterName}',
    );
  }

  /// Where the game's own movetext cursor is, so returning from the Line tab
  /// restores the board instead of leaving a book position on it.
  Position? _gamePanePosition;

  /// Mainline SANs of the game on screen, memoized by game identity.
  ///
  /// Two reasons this is not parsed in `build`: the side panel rebuilds on
  /// every controller notification (engine ticks included), and the Line panel
  /// treats a new list *instance* as a new game — so a fresh parse per frame
  /// would restart its book walk and flash it back to a spinner.
  String? _lineSansKey;
  List<String> _lineSans = const [];

  @override
  List<String> _currentGameSans(PgnGameEntry entry) {
    final key =
        '${_controller.filePath}#${entry.label}#${entry.pgnText.length}';
    if (key != _lineSansKey) {
      _lineSansKey = key;
      _lineSans = extractMainlineSans(entry.pgnText);
    }
    return _lineSans;
  }

  @override
  void _onGamePosition(Position position) {
    _gamePanePosition = position;
    _controller.onPositionChanged(position);
  }

  /// Whether the Line tab has been opened in this screen's lifetime.
  ///
  /// `TabBarView` builds every child eagerly, and the Line panel's first build
  /// walks the designated books off disk. Opening a game to read it should not
  /// pay for a question nobody asked, so the panel waits for its first visit.
  @override
  bool _lineTabVisited = false;

  /// Show the book line beside the game: the Line tab, not a dialog.
  @override
  void _showLineTab() {
    if (_controller.isSolitaireMode || !_lineTabVisible) return;
    if (!_lineTabVisited) setState(() => _lineTabVisited = true);
    _tabController.animateTo(_lineTabIndex);
  }

  /// A book-line move was selected on the Line tab — put it on the main board.
  /// The tab that has focus owns the board, which is what makes flipping
  /// between Game and Line a comparison rather than two separate viewers.
  @override
  void _showLinePosition(Position position) {
    if (_tabController.index != _lineTabIndex) return;
    _controller.onPositionChanged(position);
  }

  /// Runs after full-game analysis: every solitaire guess the user tried and
  /// had rejected is evaluated and compared to the move actually played.
  ///
  /// Solitaire itself can't do this — it only knows *whether* a guess matched,
  /// not whether it was better — and full-game analysis only evaluates moves
  /// that were played, so the comparison needs both halves together.
  @override
  Future<void> _detectTrophies() async {
    final guesses = _controller.solitaire.guessLog;
    if (guesses.isEmpty || _controller.filteredGames.isEmpty) return;

    final game = _controller.filteredGames[_controller.currentGameIndex];
    try {
      final found = await detectSolitaireTrophies(
        guesses: guesses,
        evals: _analysisController.evals,
        userIsWhite: _controller.solitaire.userIsWhite,
        depth: _analysisController.depth,
        gameLabel: game.label,
        headers: game.headers,
        pgn: game.pgnText,
        existing: await SolitaireTrophyService.instance.loadAll(),
      );
      if (found.isEmpty || !mounted) return;

      await SolitaireTrophyService.instance.addTrophies(found);
      if (!mounted) return;
      setState(() {
        _detectedTrophies = found;
        _trophyGameIndex = _controller.currentGameIndex;
      });
      _controller.noteTrophiesEarned(found.length);
      showAppSnackBar(
        context,
        found.length == 1
            ? 'Trophy earned — your ${found.first.userMove} beat '
                  '${found.first.gmMove}.'
            : '${found.length} trophies earned.',
        actionLabel: 'Cabinet',
        onAction: _showTrophyCabinet,
      );
    } catch (e) {
      debugPrint('Trophy detection failed: $e');
    }
  }

  @override
  void _showTrophyCabinet() {
    unawaited(
      showDialog(
        context: context,
        builder: (_) => SolitaireTrophyCabinet(onOpenGame: _openTrophyPosition),
      ).then((_) {
        unawaited(_controller.loadSolitaireSettings());
        _reclaimFocus();
      }),
    );
  }

  /// Put a trophy's game back on the board, parked on the position it was won
  /// in. Every trophy stores the game it came from, so revisiting one is the
  /// same operation as pasting that PGN — it replaces the open collection,
  /// which the recent-files menu is the way back from.
  Future<void> _openTrophyPosition(SolitaireTrophy trophy) async {
    _singleGameFocus = false;
    await _controller.loadPgnContent(trophy.pgn, initialFen: trophy.fen);
    if (!mounted) return;
    final error = _controller.errorMessage;
    if (error != null) {
      showAppSnackBar(context, error, duration: const Duration(seconds: 4));
    }
  }

  /// Leave a running solitaire session — asking first when guesses made so
  /// far would be thrown away — or close the setup strip.
  @override
  Future<void> _leaveSolitaire() async {
    if (!_controller.isSolitaireMode) {
      _controller.cancelSolitaireSetup();
      _reclaimFocus();
      return;
    }
    if (_controller.solitaire.hasProgress) {
      final leave = await confirmAction(
        context,
        title: 'Leave solitaire?',
        message: 'Your guesses in this game so far are lost.',
        confirmLabel: 'Leave',
        destructive: false,
      );
      if (!mounted) return;
      if (!leave) {
        _reclaimFocus();
        return;
      }
    }
    _controller.stopSolitaire();
    _reclaimFocus();
  }

  /// Run [action] (switching game) — after asking, when a solitaire game is
  /// half done.
  @override
  Future<void> _guardingSolitaireProgress(VoidCallback action) async {
    if (_controller.isSolitaireMode && _controller.solitaire.hasProgress) {
      final go = await confirmAction(
        context,
        title: 'Switch game?',
        message: 'Your guesses in this game so far are lost.',
        confirmLabel: 'Switch',
        destructive: false,
      );
      if (!mounted) return;
      if (!go) {
        _reclaimFocus();
        return;
      }
    }
    action();
  }

  /// From the completion banner: leave solitaire and put the engine on the
  /// game. Trophy detection needs both the guess log (kept after the session
  /// stops) and the evals, so it hangs off the analysis either way — a fresh
  /// run's completion, or right now when cached evals already cover the game.
  @override
  void _analyseSolitaireGame() {
    _controller.stopSolitaire();
    final cached =
        _analysisController.evals.isNotEmpty &&
        !_analysisController.isAnalyzing;
    _startAutoAnalysisForCurrentGame();
    if (cached) unawaited(_detectTrophies());
  }

  @override
  Future<void> _copyCurrentGamePgn() async {
    if (_controller.filteredGames.isEmpty) return;
    final pgnText =
        _controller.filteredGames[_controller.currentGameIndex].pgnText;
    await Clipboard.setData(ClipboardData(text: pgnText));
    if (!mounted) return;
    showAppSnackBar(context, AppMessages.pgnCopied);
    _reclaimFocus();
  }

  @override
  Future<void> _addCurrentGameToStudy() async {
    if (_controller.filteredGames.isEmpty) return;
    final game = _controller.filteredGames[_controller.currentGameIndex];
    // The guess notes are already merged into this game's movetext by the time
    // the completion banner shows, so the stored PGN is the annotated artifact.
    final pgn = game.pgnText;
    final white = game.headers['White'] ?? 'White';
    final black = game.headers['Black'] ?? 'Black';
    final suggested = '$white – $black (solitaire)';

    await runAddToStudyFlow(
      context,
      suggestedChapterName: suggested,
      pickerTitle: 'Add game to study',
      viewActionLabel: 'View game',
      buildPgn: (_) => pgn,
    );
    _reclaimFocus();
  }

  @override
  Future<void> _exportSlice() async {
    if (_controller.filteredGames.isEmpty || _controller.filePath == null) {
      return;
    }

    final defaultName = _controller.defaultExportFileName();
    if (defaultName == null) return;

    final content = _controller.buildExportContent();
    final outPath = await FilePicker.saveFile(
      dialogTitle: 'Export ${_controller.filteredGames.length} filtered games',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: ['pgn'],
      initialDirectory: p.dirname(_controller.filePath!),
      bytes: utf8.encode(content),
    );
    if (outPath == null) {
      _reclaimFocus();
      return;
    }

    if (!mounted) return;
    final fileName = p.basename(outPath);
    showAppSnackBar(
      context,
      'Exported ${_controller.filteredGames.length} games to $fileName',
      duration: const Duration(seconds: 4),
      actionLabel: 'Open',
      onAction: () => _loadFile(outPath),
    );
    _reclaimFocus();
  }

  @override
  void _toggleEditMode() {
    setState(() => _editMode = !_editMode);
  }

  /// The Browse↔Edit toggle (A). A study file reopens in Study mode on the
  /// same chapter and position; any other collection offers the safe path —
  /// copy the current game into a study and edit it there. (In-place study
  /// editing of a shared collection is deliberately not offered: Study
  /// autosave rewrites the whole file, which a games cache can't tolerate.)
  @override
  Future<void> _editInStudy() async {
    final games = _controller.filteredGames;
    if (games.isEmpty) return;
    final path = _controller.filePath;
    final game = games[_controller.currentGameIndex];

    final played = _pgnWidgetController.mainLineIndex;
    final sanLine = played <= 0
        ? null
        : _pgnWidgetController.mainLineMoves.take(played).toList();

    if (path != null && await _isStudyPath(path)) {
      final indexInFile = _controller.allGames.indexOf(game);
      if (!mounted) return;
      context.read<AppState>().switchToStudyEdit(
        path: path,
        chapterIndex: indexInFile < 0 ? null : indexInFile,
        initialSanLine: sanLine,
      );
      return;
    }

    if (!mounted) return;
    final white = game.headers['White'] ?? 'White';
    final black = game.headers['Black'] ?? 'Black';
    await runAddToStudyFlow(
      context,
      suggestedChapterName: '$white – $black',
      pickerTitle: 'Edit game in a study',
      viewActionLabel: 'Edit in study',
      buildPgn: (_) => game.pgnText,
      viewSanLine: sanLine,
    );
    _reclaimFocus();
  }

  Future<bool> _isStudyPath(String path) async {
    final dir = await AppPaths.studiesDirectory();
    return p.isWithin(dir.path, path);
  }

  /// "Save filtered games as study…": promote the current slice (or the whole
  /// collection when unsliced) into a study of its own — the bridge from
  /// exploring a big collection to curating the interesting games.
  @override
  Future<void> _saveSliceAsStudy() async {
    final games = _controller.filteredGames;
    if (games.isEmpty) return;

    final suggested = _controller.filePath == null
        ? 'New study'
        : p.basenameWithoutExtension(_controller.filePath!);
    final name = await showNameEntryDialog(
      context,
      title: 'Save ${games.length} games as study',
      fieldLabel: 'Study name',
      confirmLabel: 'Save',
      initialValue: suggested,
      allowUnchanged: true,
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) {
      _reclaimFocus();
      return;
    }

    final study = context.read<StudyController>();
    final appState = context.read<AppState>();
    final path = await study.createStudyFromPgn(
      trimmed,
      _controller.buildExportContent(),
    );
    if (!mounted) return;
    showAppSnackBar(
      context,
      'Saved ${games.length} game${games.length == 1 ? '' : 's'} as '
      '"${study.doc.name}".',
      actionLabel: 'Edit study',
      onAction: () => appState.switchToStudyEdit(path: path),
    );
    _reclaimFocus();
  }

  Future<void> _openGameSearch() async {
    if (_controller.showOpeningTree) {
      await openTreePositionGameSearch(
        context: context,
        controller: _controller,
      );
      _reclaimFocus();
      return;
    }
    if (_controller.filteredGames.isEmpty) return;
    final selected = await showGameSearchDialog(
      context: context,
      games: [
        for (final g in _controller.filteredGames) GameNavItem.fromEntry(g),
      ],
      currentIndex: _controller.currentGameIndex,
    );
    if (selected != null) _controller.goToGame(selected);
    _reclaimFocus();
  }

  static const _digitKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  /// Whether the Line tab is the one on screen (and so owns the board and the
  /// arrow keys).
  bool get _onLineTab =>
      !_controller.isSolitaireMode && _tabController.index == _lineTabIndex;

  /// The viewer's keyboard shortcuts, dispatched through [handleKeyBindings]
  /// (never while typing). Order matters: the solitaire block shadows keys
  /// that would disturb a puzzle. Keep descriptions in sync with the button
  /// tooltips that advertise them.
  List<KeyBinding> get _keyBindings => [
    // Solitaire: arrows/Home/End still browse the revealed region (the PGN
    // widget caps mainline navigation at the frontier); R reveals, and the
    // autoplay/tab-switch/engine/amend keys are swallowed so they can't
    // disturb the puzzle.
    if (_controller.isSolitaireMode) ...[
      // preempts: solitaire deliberately shadows the normal meaning of these
      // keys — R stops being "return to mainline", and the four below stop
      // doing anything at all. Saying so here is what keeps the dead-binding
      // check from flagging the ones underneath.
      ...KeyBinding.forShortcut(
        AppShortcut.revealMove,
        'Reveal current move',
        () {
          if (_controller.solitaire.canReveal) _controller.revealCurrentMove();
        },
        preempts: true,
      ),
      ...KeyBinding.forShortcut(
        AppShortcut.hintMove,
        'Hint: highlight the piece that moves',
        _controller.hintCurrentMove,
      ),
      for (final shortcut in [
        AppShortcut.autoPlay,
        AppShortcut.nextTab,
        AppShortcut.toggleEngine,
        AppShortcut.amendGame,
      ])
        ...KeyBinding.forShortcutIf(
          shortcut,
          'Disabled during solitaire',
          () => true,
          preempts: true,
        ),
    ],
    // Arrows step whichever pane is on screen: the book line while the Line
    // tab is up, the game otherwise. Keys that move a board the user isn't
    // looking at are how the Line tab would have felt broken.
    ...KeyBinding.forShortcut(
      AppShortcut.backOneMove,
      'Back one move',
      () => _onLineTab
          ? _lineWidgetController.goBack()
          : _controller.navigateBack(),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.forwardOneMove,
      'Forward one move',
      () => _onLineTab
          ? _lineWidgetController.goForward()
          : _controller.navigateForward(),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.goToStart,
      'Go to start',
      _controller.navigateToStart,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.goToEnd,
      'Go to end',
      _controller.navigateToEnd,
    ),
    // P/S (and ↓/↑) step the game list — the app-wide pair for "previous /
    // next thing in the queue in front of me", while ←/→ stay on moves. Both
    // chords are move-text safe, which is the whole reason the pair is P/S and
    // not N/P: N is the knight.
    ...KeyBinding.forShortcut(
      AppShortcut.nextItem,
      'Next game',
      _controller.nextGame,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.previousItem,
      'Previous game',
      _controller.prevGame,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.fullScreen,
      'Toggle fullscreen',
      _controller.toggleFullScreen,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.flipBoard,
      'Flip board',
      _controller.toggleBoardFlipped,
    ),
    ...KeyBinding.forShortcut(AppShortcut.pastePgn, 'Paste PGN', _pastePgn),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleEngine,
      'Toggle engine',
      InlineEngineBar.toggleEngine,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.autoPlay,
      'Toggle auto-play',
      _controller.toggleAutoPlay,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.autoNextGame,
      'Toggle auto next game',
      () => _controller.setAutoNextGame(!_controller.autoNextGame),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.amendGame,
      'Edit in Study',
      _editInStudy,
    ),
    // Search moved off S when S became "next game": one key, one meaning,
    // app-wide. `/` is the search key everywhere it is free, and it is free
    // here because the viewer has no move box for it to focus. While the
    // opening tree is up the nav bar is gone, so `/` searches the games at
    // the current tree position instead of the whole file.
    ...KeyBinding.forShortcut(
      AppShortcut.searchGames,
      'Search games',
      _openGameSearch,
    ),
    // Straight to the nav bar's number box — a game number you already know
    // never needs the search dialog. Falls through when no box is on screen.
    ...KeyBinding.forShortcutIf(
      AppShortcut.goToGameNumber,
      'Go to game number',
      GameNumberField.focusActive,
    ),
    // The setup strip: Enter starts, Escape (below) closes it.
    if (_controller.isSolitaireSetup)
      KeyBinding(LogicalKeyboardKey.enter, 'Start solitaire', () {
        _controller.beginSolitaire();
        return true;
      }),
    // Escape leaves whatever you are in, innermost first — the ordering is the
    // whole contract: solitaire and amend are modes you entered, full screen is
    // a view you entered, and scratch analysis moves are the only thing left to
    // back out of once you are in none of them. Leaving a half-played
    // solitaire game asks first.
    ...KeyBinding.forShortcut(
      AppShortcut.leave,
      'Exit solitaire / amend / fullscreen, clear analysis moves',
      () {
        if (_controller.isSolitaireMode || _controller.isSolitaireSetup) {
          unawaited(_leaveSolitaire());
        } else if (_editMode) {
          _toggleEditMode();
        } else if (_controller.isFullScreen) {
          unawaited(_controller.exitFullScreen());
        } else {
          _pgnWidgetController.clearEphemeralMoves();
        }
      },
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.nextTab,
      'Next tab',
      () => _tabController.animateTo(
        (_tabController.index + 1) % _tabController.length,
      ),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.returnToMainline,
      'Return to mainline',
      () {
        if (_pgnWidgetController.inVariation) {
          _pgnWidgetController.returnToMainline();
        }
      },
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleOpeningTree,
      'Toggle opening tree',
      _controller.toggleOpeningTree,
    ),
    // Play the numbered branch candidate shown in the fork bar. The one
    // family of keys with no registry entry: "the nth digit" is an index, not
    // a named action, and the fork bar labels each candidate with its own
    // number rather than advertising a shortcut in a tooltip.
    for (var i = 0; i < _digitKeys.length; i++)
      KeyBinding(
        _digitKeys[i],
        'Play fork candidate ${i + 1}',
        () => _pgnWidgetController.selectBranchCandidate(i),
      ),
    // Ctrl+S is the one people reach for; Shift+S stays because it is what the
    // mode has always answered to. Neither collides with the bare S that steps
    // to the next game — a chord's modifiers are part of its identity.
    // Escape (above) is the way out of the mode.
    ...KeyBinding.forShortcutIf(
      AppShortcut.solitaire,
      'Toggle solitaire mode',
      _toggleSolitaireMode,
    ),
    // Jump into the annotation panel's comment field (amend mode only).
    ...KeyBinding.forShortcutIf(
      AppShortcut.commentMove,
      'Comment current move',
      PgnAnnotationPanel.focusActive,
    ),
  ];

  /// Solitaire is refused while the opening tree owns the board — the tree is
  /// a view of every game at once and there is no single game to guess through.
  /// Returns true either way: refusing is an answer, not a fall-through to
  /// some other binding.
  @override
  bool _toggleSolitaireMode() {
    if (_controller.showOpeningTree) return true;
    if (_controller.isSolitaireMode) {
      unawaited(_leaveSolitaire());
    } else {
      _controller.toggleSolitaire();
      // The setup strip and the game itself live in the Game tab; opening
      // setup from Analysis or Line would otherwise light the icon and show
      // nothing.
      if (_controller.isSolitaireSetup) _tabController.animateTo(_kGameTab);
    }
    return true;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) =>
      handleKeyBindings(_keyBindings, event, node: node);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reclaimFocus,
        child: _controller.isFullScreen
            ? _buildFullScreenView(theme)
            : Scaffold(
                appBar: _buildAppBar(theme),
                body: Stack(
                  children: [
                    ResponsiveSplitLayout(
                      breakpoint: kCompactBreakpoint,
                      primary: _buildBoardPane(),
                      secondary: _buildSidePanel(),
                    ),
                    if (_controller.isLoading)
                      Positioned.fill(
                        child: ColoredBox(
                          color: AppColors.scrim,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
