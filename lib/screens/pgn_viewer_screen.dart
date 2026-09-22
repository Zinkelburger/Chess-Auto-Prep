/// PGN Viewer mode — browse master game collections for study.
///
/// Features: file picker, position/header-based dataset slicing, game-by-game
/// navigation with counter, optional playback, study curation, and full-game
/// Stockfish analysis with eval graph, inline engine bar, and comment editing.
///
/// The screen state is split across part files: app-bar builders in
/// `pgn_viewer_screen_app_bar.dart`, body/pane builders in
/// `pgn_viewer_screen_panes.dart`.
library;

import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';

import 'dart:async';

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import '../app/pgn_viewer_lifetime.dart';
import '../design_system/components/name_entry_dialog.dart';
import '../features/documents/controllers/document_save_session.dart';
import '../features/documents/models/pgn_document.dart';
import '../features/documents/widgets/document_save_dialog.dart';
import '../l10n/generated/app_localizations.dart';
import 'package:dartchess/dartchess.dart'
    show Chess, Setup, PgnGame, PgnNodeData, Position;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../core/app_history.dart';
import '../services/scid/scid_writer.dart';
import '../utils/open_in_file_manager.dart';
import '../features/documents/controllers/viewer_document_controller.dart';
import '../features/documents/repositories/pgn_viewer_handle.dart';
import '../chess_core/pgn/pgn_copy.dart';
import '../features/documents/controllers/solitaire_controller.dart';
import '../features/games/services/game_deviation_service.dart';
import '../features/games/services/opening_review.dart' show deviationVerdict;
import '../chess_core/pgn/mainline_lexer.dart' show mainlineSansOf;
import '../features/games/services/my_repertoire_settings.dart';
import '../features/games/widgets/repertoire_line_panel.dart';
import '../services/games_library/game_filter.dart' show dedupKeyForHeaders;
import '../services/storage/app_paths.dart';
import '../services/lichess_auth_service.dart';
import '../services/storage/storage_factory.dart';
import '../services/game_analysis_controller.dart';
import '../models/board_annotation.dart';
import '../models/explorer_response.dart';
import '../models/solitaire_trophy.dart';
import '../services/solitaire_trophy_detector.dart';
import '../services/solitaire_trophy_service.dart';
import '../services/explorer_game_opener.dart';
import '../services/live_explorer_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/chess_utils.dart' show playSanOrNullMove, uciHighlightSquares;
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../features/games/widgets/game_view_settings_dialog.dart';
import '../widgets/app_settings_button.dart';
import '../design_system/components/confirm_dialog.dart';
import '../widgets/engine/engine_gate.dart';
import '../widgets/layout/responsive_split_layout.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/fullscreen_game_view.dart';
import '../widgets/game_analysis_tab.dart';
import '../features/documents/controllers/pgn_workspace.dart';
import '../widgets/pgn/pgn_workspace_bar.dart';
import '../widgets/pgn/pgn_slice_chips.dart';
import '../widgets/pgn/pgn_collection_panel.dart';
import '../features/games/models/game_view_preferences.dart';
import '../features/games/widgets/add_games_to_study.dart';
import '../widgets/game_nav_bar.dart';
import '../widgets/game_number_field.dart';
import '../widgets/game_search_dialog.dart';
import '../widgets/study/add_to_study_flow.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/pgn/pgn_opening_tree_panel.dart';
import '../widgets/pgn/pgn_opening_label.dart';
import '../widgets/pgn/pgn_tree_toolbar.dart';
import '../widgets/pgn/solitaire_status_widgets.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/pgn/pgn_game_filter_workspace.dart';
import '../models/pgn_filter_models.dart';
import '../widgets/solitaire_trophy_cabinet.dart';
import '../widgets/opening_explorer/opening_explorer_panel.dart';

part 'pgn_viewer_screen_app_bar.dart';
part 'pgn_viewer_screen_panes.dart';

/// Side-panel tab indices. Game is always 0. Line is only present when
/// reviewing one of your games from the Games/tactics handoff; Analysis
/// sits at 1 otherwise. Named getters (not constants) so an `animateTo(1)`
/// cannot silently mean the wrong tab.
const int _kGameTab = 0;

class PgnViewerScreen extends StatefulWidget {
  const PgnViewerScreen({super.key, required this.lifetime});
  final PgnViewerLifetime lifetime;

  @override
  State<PgnViewerScreen> createState() => _PgnViewerScreenState();
}

class _PgnViewerScreenState extends State<PgnViewerScreen>
    with _AppBarBuildersMixin, _PaneBuildersMixin {
  String? get _viewerError =>
      _document.errorMessage ??
      _document.editor.errorMessage ??
      _document.reading.errorMessage ??
      _document.libraryState.errorMessage ??
      (_document.filters.error == null
          ? null
          : 'Could not filter these games. Try again.') ??
      (_document.presentation.error == null
          ? null
          : 'Could not change the window view. Try again.');

  @override
  late final ViewerDocumentController _document;
  @override
  late final PgnViewerWidgetController _pgnWidgetController;

  /// Movetext cursor for the Book tab's repertoire line, so controls drive whichever
  /// pane is on screen instead of always the game.
  @override
  late final PgnViewerWidgetController _lineWidgetController;
  PgnViewerHandle? get _movementReader => _document.presentation.isFullScreen
      ? _pgnWidgetController
      : (_onLineTab ? _lineWidgetController : null);
  @override
  late final GameAnalysisController _analysisController;
  @override
  late final PgnWorkspace _tabController;
  List<PgnGameEntry>? _filterSource;
  List<GameRecord> _filterRecords = [];
  int? _filterRevision;
  String? _filterOriginFen;
  List<PgnGameEntry>? _filterReturnSource;

  @override
  bool get _canReturnToFilters =>
      _filterReturnSource != null &&
      identical(_filterReturnSource, _document.collection.games) &&
      _tabController.index == PgnWorkspace.game;

  @override
  void _returnToFilters() {
    if (!mounted || !_canReturnToFilters) return;
    _document.reading.playback.stop();
    _tabController.index = PgnWorkspace.filters;
    setState(() => _filterReturnSource = null);
    _reclaimFocus();
  }

  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnViewerScreen');

  @override
  bool _editMode = false;

  bool _singleGameFocusValue = false;

  bool get _singleGameFocus => _singleGameFocusValue;

  /// Repertoire comparison is available for imports as well as handoffs.
  bool get _lineTabVisible => true;

  int get _lineTabIndex => _lineTabVisible ? 1 : -1;

  int get _explorerTabIndex => PgnWorkspace.explorer;

  @override
  int get _analysisTabIndex => _lineTabVisible ? 3 : 2;

  /// The opening explorer beside the game: what the databases say about the
  /// position on the board, and the games they list for it.  Owned here the
  /// way the repertoire panes own theirs — the service holds a debounce timer
  /// and an HTTP client, so the screen that shows it disposes it.
  @override
  late final LiveExplorerService _explorer;
  late final ExplorerGameOpener _gameOpener;

  /// The explorer row under the pointer, echoed on the board as an arrow.
  @override
  ExplorerMove? _explorerHoverMove;

  @override
  set _singleGameFocus(bool value) {
    if (_singleGameFocusValue == value) return;
    _singleGameFocusValue = value;
    if (mounted) setState(() {});
  }

  /// Cached so [dispose] does not [BuildContext.read] after unmount.
  AppState? _appState;
  VoidCallback? _unregisterHistoryContext;
  int _navigationRestoreEpoch = 0;

  @override
  void initState() {
    super.initState();
    // Game · Explorer · Analysis by default. Line is added only for a
    // Games/tactics handoff (see [_lineTabVisible]).
    _tabController = PgnWorkspace();
    _explorer = LiveExplorerService();
    _gameOpener = ExplorerGameOpener();
    _pgnWidgetController = widget.lifetime.reader;
    _lineWidgetController = PgnViewerWidgetController();
    _analysisController = widget.lifetime.analysis;
    _analysisController.addListener(_onAnalysisUpdate);
    _document = widget.lifetime.document;
    widget.lifetime.reclaimFocus = _reclaimFocus;
    _document.changes.addListener(_onControllerUpdate);
    MyRepertoireSettings.instance.addListener(_onRepertoireDesignationsChanged);
    // Leaving the Book tab hands the board back to the game: the tab you are
    // reading owns the board, so flipping between them is a comparison of the
    // same position rather than two viewers fighting over one board.
    _tabController.addListener(_onSideTabChanged);
    final preferencesReady = _loadViewPreferences();
    unawaited(_document.libraryState.loadRecentFiles());
    unawaited(_document.libraryState.loadCollections());
    unawaited(_document.reading.loadSolitaireSettings());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        _appState = appState;
        _unregisterHistoryContext = context
            .read<AppHistory?>()
            ?.registerContext(AppMode.pgnViewer, _captureNavigationContext);
        appState.addListener(_onAppStateChanged);
        // The screen may have been created by the very mode switch that set
        // the pending file (listener not registered yet) — consume it now.
        _consumePendingViewerFile(appState);
        unawaited(
          preferencesReady.then((_) async {
            if (mounted) await _document.restoreLastSession();
          }),
        );
      }
    });
  }

  @override
  GameViewPreferences _viewPreferences = const GameViewPreferences();
  bool _preferencesChanged = false;
  @override
  ({String fen, String? uci})? _engineThreat;
  @override
  void _setEngineThreat(String fen, String? uci) {
    if (!mounted || _engineThreat == (fen: fen, uci: uci)) return;
    setState(() => _engineThreat = (fen: fen, uci: uci));
  }

  @override
  bool _viewingStudy = false;
  String? _studyPathChecked;

  Future<void> _loadViewPreferences() async {
    final saved = await GameViewPreferences.load();
    if (!mounted || _preferencesChanged) return;
    setState(() => _viewPreferences = saved);
    _document.reading.playback.setSpeed(saved.speed);
    _document.reading.playback.setAutoNextGame(saved.autoNext);
    _document.editor.setAutoSave(saved.autoSave);
    _document.setAutoDetectOpenings(saved.autoDetectOpenings);
  }

  @override
  void _setViewPreferences(GameViewPreferences value) {
    if (!mounted) return;
    _preferencesChanged = true;
    setState(() {
      if (_viewPreferences.engine != value.engine) _engineThreat = null;
      _viewPreferences = value;
    });
    if (!value.playback) _document.reading.playback.stop();
    _document.reading.playback.setSpeed(value.speed);
    _document.reading.playback.setAutoNextGame(value.autoNext);
    _document.editor.setAutoSave(value.autoSave);
    _document.setAutoDetectOpenings(value.autoDetectOpenings);
    unawaited(value.save());
  }

  void _toggleEngine() {
    if (!mounted ||
        _document.collection.visibleGames.isEmpty ||
        _document.reading.solitaire.isConfiguring) {
      return;
    }
    final hidden = !_viewPreferences.engine;
    if (hidden) {
      _setViewPreferences(_viewPreferences.copyWith(engine: true));
    }
    _showPanel(PgnWorkspace.game);
    // Revealing an already enabled engine must not turn it off. Subsequent
    // presses toggle analysis while leaving the panel in place.
    if (!hidden || !InlineEngineBar.isEngineEnabled(context)) {
      InlineEngineBar.toggleEngine(context);
    }
  }

  Future<void> _checkStudyPath(String? path) async {
    final isStudy = path != null && await _isStudyPath(path);
    if (mounted && _document.filePath == path) {
      setState(() => _viewingStudy = isStudy);
    }
  }

  @override
  void _showPanel(int index) {
    _document.reading.playback.stop();
    if (!mounted) return;
    if (index == PgnWorkspace.filters && _tabController.index != index) {
      if (!identical(_filterReturnSource, _document.collection.games)) {
        _filterOriginFen = normalizeFen(_document.reading.currentPosition.fen);
      }
      _filterReturnSource = null;
    }
    if (index == _lineTabIndex) _lineTabVisited = true;
    _tabController.index = index;
    setState(() {});
    _reclaimFocus();
  }

  @override
  void _closePanel(int id) {
    if (!mounted) return;
    _document.reading.playback.stop();
    _tabController.close(id);
    if (id == PgnWorkspace.filters) _filterReturnSource = null;
    setState(() {});
    _reclaimFocus();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (_studyPathChecked != _document.filePath) {
      _studyPathChecked = _document.filePath;
      _viewingStudy = false;
      unawaited(_checkStudyPath(_studyPathChecked));
    }
    // Trophies belong to one game's analysis; the banner and the per-move
    // markers key off its positions, so they must not survive a game switch.
    if (_detectedTrophies.isNotEmpty &&
        _document.collection.selectedIndex != _trophyGameIndex) {
      _detectedTrophies = const [];
    }
    _tabController.synchronizeTree(_document.reading.tree.showOpeningTree);
    _maybeUpdateDeviation();
    setState(() {});
  }

  void _onAppStateChanged() {
    final appState = _appState;
    if (appState == null) return;
    final isCurrent = appState.currentMode == AppMode.pgnViewer;
    if (!isCurrent) {
      _navigationRestoreEpoch++;
      return;
    }
    _consumePendingViewerFile(appState);
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

  VoidCallback _captureNavigationContext() {
    final restoreCollection = _document.captureNavigationContext();
    final selectedTab = _tabController.index;
    final openTabs = _tabController.openTabs;
    final singleGame = _singleGameFocus;
    return () {
      if (!mounted) return;
      final epoch = ++_navigationRestoreEpoch;
      unawaited(() async {
        final restored = await restoreCollection();
        if (!mounted || !restored || epoch != _navigationRestoreEpoch) return;
        _singleGameFocus = singleGame;
        for (final tab in _tabController.openTabs) {
          if (!openTabs.contains(tab)) _tabController.close(tab);
        }
        for (final tab in openTabs) {
          _tabController.openInBackground(tab);
        }
        _tabController.index = selectedTab;
      }());
    };
  }

  Future<void> _openFromHandoff(OpenPgnViewer handoff) async {
    final epoch = ++_navigationRestoreEpoch;
    final gameId = handoff.gameId;
    // Arriving with one game named is a different job from opening a
    // collection: the app bar's slice machinery (player presets, add-filter
    // chip, filtered/total counter) is about carving a dataset up, and none of
    // it applies to "show me this game". [_singleGameFocus] takes it off the
    // bar; opening any file yourself brings it back.
    _singleGameFocus = gameId != null;

    final path = handoff.pgnPath;
    final bool opened;
    if (path == null) {
      if (!await _confirmLeavePgn() || !_isCurrentNavigation(epoch)) return;
      opened = await _document.loadPgnContent(
        handoff.content!,
        title: handoff.title,
      );
    } else {
      // Fast path: the requested game lives in the file that's already open
      // (Games page → Review → breadcrumb back → Review again). Reloading
      // would re-parse the whole games cache and — worse — cancel and forget
      // an analysis that is still running, so reuse the loaded collection.
      final sameFileLoaded =
          handoff.sliceFen == null &&
          gameId != null &&
          path == _document.filePath &&
          _document.errorMessage == null &&
          _document.collection.games.isNotEmpty &&
          // ...and the loaded copy is still what is on disk. The review of your
          // recent games writes the scores it found back into the games cache,
          // so a collection read before a run is a collection whose games have
          // no graph — reusing it would draw a blank chart over evals that are
          // sitting in the file.
          await _loadedCopyIsCurrent(path);
      if (!_isCurrentNavigation(epoch)) return;
      if (sameFileLoaded) {
        if (_currentGameIs(gameId)) {
          _applyHandoffTab(handoff, epoch);
          return;
        }
        if (await _goToGameById(gameId)) {
          if (!_isCurrentNavigation(epoch)) return;
          _applyHandoffTab(handoff, epoch);
          return;
        }
        // Not in the loaded copy (the cache gained games since) — fall through
        // to a full reload.
        if (!_isCurrentNavigation(epoch)) return;
      }

      opened = await _openFileWithPositionSlice(
        path,
        handoff.sliceFen,
        navigationEpoch: epoch,
        // A single-game handoff must not resurrect an old slice: it can hide
        // the target game and its filtered/total counter reads as noise when
        // all you asked for was one game. Same for a file-position jump —
        // a restored slice would shift the indices it was computed against.
        restoreSavedSlice: gameId == null && handoff.gameIndex == null,
      );
    }
    if (!_isCurrentNavigation(epoch) || !opened || _document.filePath != path) {
      return;
    }
    if (gameId != null) {
      final found = await _goToGameById(gameId);
      if (!found || !_isCurrentNavigation(epoch)) return;
    } else if (handoff.gameIndex != null &&
        _document.collection.visibleGames.isNotEmpty) {
      final selected = await _document.reading.selectGame(
        handoff.gameIndex!.clamp(
          0,
          _document.collection.visibleGames.length - 1,
        ),
      );
      if (!selected || !_isCurrentNavigation(epoch)) return;
    }
    _applyHandoffTab(handoff, epoch);
  }

  /// Land on the tab that answers the question the handoff asked, and start the
  /// engine only when it was the engine's answer that was wanted.
  ///
  /// Solitaire hides the side-panel tabs entirely; don't fight the mode.
  bool _isCurrentNavigation(int epoch) =>
      mounted && epoch == _navigationRestoreEpoch;

  void _applyHandoffTab(OpenPgnViewer handoff, int epoch) {
    if (!_isCurrentNavigation(epoch)) return;
    if (_document.reading.solitaire.isActive) return;
    // Recent-game clicks keep the annotated Game reader selected, with the
    // saved graph ready in its own tab. Restoring scores needs no engine pass.
    if (handoff.gameId != null && _analysisController.evals.isNotEmpty) {
      _tabController.openInBackground(_analysisTabIndex);
    }
    switch (handoff.tab) {
      case PgnViewerTab.game:
        _tabController.animateTo(_kGameTab);
      case PgnViewerTab.line:
        _showLineTab();
      case PgnViewerTab.explorer:
        _tabController.animateTo(_explorerTabIndex);
      case PgnViewerTab.analysis:
        _tabController.animateTo(_analysisTabIndex);
    }
    if (handoff.autoAnalyze) _startAutoAnalysisForCurrentGame();
    final ply = handoff.ply;
    if (ply != null) {
      // The PGN widget takes the newly selected game on its next build and
      // parks the cursor at the start; move it after that build, not before.
      final selectionRevision = _document.collection.selectionRevision;
      final selectedGame = _document.collection.selectedGame;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isCurrentNavigation(epoch) ||
            _document.collection.selectionRevision != selectionRevision ||
            !identical(_document.collection.selectedGame, selectedGame))
          return;
        _document.reading.goToPly(ply);
      });
    }
  }

  /// Whether the open collection still matches its file on disk.
  ///
  /// True when the mtimes agree, and true when either is unavailable: an
  /// unreadable stat is not evidence of a change, and treating it as one would
  /// re-parse the whole games cache on every handoff.
  Future<bool> _loadedCopyIsCurrent(String path) async {
    final loadedAt = _document.loadedFileModified;
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
    final games = _document.collection.visibleGames;
    if (games.isEmpty || _document.collection.selectedIndex >= games.length) {
      return null;
    }
    return dedupKeyForHeaders(
      games[_document.collection.selectedIndex].headers,
      pgn: games[_document.collection.selectedIndex].pgnText,
    );
  }

  Future<bool> _goToGameById(String gameId) async {
    // Newest-first before locating it: this game came from the recent-games
    // list, and the games cache's file order is a download log — the game you
    // played five minutes ago sits wherever its batch landed ("Game 301 of
    // 312"). Sorted, the counter agrees with the list you clicked from, and
    // Prev/Next walk back through time instead of through fetch history.
    _document.sortNewestFirst();
    var index = _document.collection.visibleGames.indexWhere(
      (g) => dedupKeyForHeaders(g.headers, pgn: g.pgnText) == gameId,
    );
    if (index < 0) {
      // A restored slice may hide the target game — widen to the whole file.
      // (resetFilters re-applies the sort, so the order survives.)
      _document.resetFilters();
      index = _document.collection.visibleGames.indexWhere(
        (g) => dedupKeyForHeaders(g.headers, pgn: g.pgnText) == gameId,
      );
    }
    if (index < 0) return false;
    return _document.reading.selectGame(index);
  }

  /// Start the engine review of the current game unless cached `[%eval]`s
  /// already cover it. Mirrors the Analysis tab's manual "Analyze Game"
  /// button, including persistence and trophy detection.
  void _startAutoAnalysisForCurrentGame() {
    if (_document.collection.visibleGames.isEmpty) return;
    _showPanel(_analysisTabIndex);
    if (_analysisController.isAnalyzing) return;
    if (_analysisController.evals.isNotEmpty) return;
    if (!EngineGate.ensureAvailable(context)) return;
    unawaited(
      _analysisController.analyzeGame(
        _document
            .collection
            .visibleGames[_document.collection.selectedIndex]
            .pgnText,
        onAnnotatedMovetext: _document.editor.persistMoveComments,
        onComplete: _detectTrophies,
      ),
    );
  }

  Future<bool> _openFileWithPositionSlice(
    String path,
    String? sliceFen, {
    bool restoreSavedSlice = true,
    int? navigationEpoch,
  }) async {
    final epoch = navigationEpoch ?? ++_navigationRestoreEpoch;
    // When a position slice is about to be applied it supersedes any restored
    // slice, so a "Restored last slice" notice would be misleading.
    final loaded = await _loadFile(
      path,
      navigationEpoch: epoch,
      notifySliceRestore: sliceFen == null && restoreSavedSlice,
      restoreSavedSlice: restoreSavedSlice,
    );
    if (!_isCurrentNavigation(epoch) || !loaded || _document.filePath != path)
      return false;
    if (_document.collection.games.isEmpty || sliceFen == null) return true;
    final source = _document.collection.games;
    await _document.recomputeAndApplyConfig(
      SliceConfig(positionInput: sliceFen),
    );
    if (!_isCurrentNavigation(epoch) ||
        !identical(source, _document.collection.games) ||
        _document.filters.error != null)
      return false;
    final count = _document.collection.visibleGames.length;
    showAppSnackBar(
      context,
      'Showing $count game${count == 1 ? '' : 's'} containing the position',
      actionLabel: 'Show All',
      onAction: () => _document.resetFilters(),
    );
    return true;
  }

  void _onAnalysisUpdate() {
    if (mounted) setState(() {});
  }

  void _onSideTabChanged() {
    if (!mounted) return;
    _document.reading.playback.stop();
    final wantTree =
        _tabController.index == PgnWorkspace.tree &&
        !_tabController.databaseTree;
    if (wantTree != _document.reading.tree.showOpeningTree) {
      _document.reading.toggleOpeningTree();
    }
    setState(() {});
    if (wantTree) return;
    if (_tabController.index == PgnWorkspace.filters &&
        _filterOriginFen != null) {
      _document.reading.onPositionChanged(
        Chess.fromSetup(Setup.parseFen(expandFen(_filterOriginFen!))),
      );
      return;
    }
    if (_tabController.index == _lineTabIndex) {
      // Book has its own cursor. Never leave the hidden Game reader advancing
      // or editing behind it after a tab switch.
      _document.reading.playback.stop();
      final needsRebuild = !_lineTabVisited || _editMode;
      _lineTabVisited = true;
      _editMode = false;
      if (needsRebuild) setState(() {});
      if (_bookPanePosition case final position?) {
        _document.reading.onPositionChanged(position);
      }
      return;
    }
    final gamePosition = _gamePanePosition;
    if (gamePosition != null) _document.reading.onPositionChanged(gamePosition);
  }

  @override
  void dispose() {
    _unregisterHistoryContext?.call();
    _appState?.removeListener(_onAppStateChanged);
    MyRepertoireSettings.instance.removeListener(
      _onRepertoireDesignationsChanged,
    );
    _document.changes.removeListener(_onControllerUpdate);
    widget.lifetime.reclaimFocus = null;
    _analysisController.removeListener(_onAnalysisUpdate);
    _explorer.dispose();
    _tabController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void _reclaimFocus() =>
      reclaimFocusAfterFrame(_focusNode, mounted: () => mounted);

  @override
  Future<void> _pickFile() async {
    final epoch = ++_navigationRestoreEpoch;
    _singleGameFocus = false;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
      initialDirectory: _document.libraryState.pickFileInitialDirectory(
        _document.filePath,
      ),
    );
    if (!_isCurrentNavigation(epoch) || file == null || file.path == null)
      return;
    await _loadFile(file.path!, navigationEpoch: epoch);
  }

  @override
  Future<void> _pastePgn() async {
    final epoch = ++_navigationRestoreEpoch;
    if (!await _confirmLeavePgn() || !_isCurrentNavigation(epoch)) return;
    _singleGameFocus = false;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!_isCurrentNavigation(epoch)) return;
    final loaded = await _document.loadPgnContent(data?.text ?? '');
    if (!_isCurrentNavigation(epoch)) return;
    if (!loaded) {
      final error = _document.errorMessage ?? _document.editor.errorMessage;
      if (error != null) {
        showAppSnackBar(
          context,
          error,
          isError: true,
          duration: const Duration(seconds: 4),
        );
      }
      return;
    }
    showAppSnackBar(
      context,
      'Loaded ${_document.collection.games.length} game(s) from clipboard',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Future<bool> _loadFile(
    String path, {
    bool notifySliceRestore = true,
    bool restoreSavedSlice = true,
    int? navigationEpoch,
  }) async {
    final epoch = navigationEpoch ?? ++_navigationRestoreEpoch;
    if (!await _confirmLeavePgn() || !_isCurrentNavigation(epoch)) return false;
    final loaded = await _document.loadFile(
      path,
      restoreSavedSlice: restoreSavedSlice,
    );
    if (!_isCurrentNavigation(epoch)) return false;
    if (!loaded) {
      final error = _document.errorMessage ?? _document.editor.errorMessage;
      if (error != null) {
        showAppSnackBar(
          context,
          error,
          isError: true,
          duration: const Duration(seconds: 5),
        );
      }
      return false;
    }
    if (notifySliceRestore) _showPendingSliceRestoreSnackBar();
    return true;
  }

  /// "Close file": drop the collection and land back on the start screen.
  ///
  /// The screen's own per-file modes go with it — amend mode, single-game
  /// focus and the trophies found in one game are all about a game that no
  /// longer exists — and the side panel returns to the Game tab, since Line
  /// and Analysis have nothing to say about an empty viewer.
  @override
  Future<void> _closeFile() async {
    final epoch = ++_navigationRestoreEpoch;
    if (!await _confirmLeavePgn() || !_isCurrentNavigation(epoch)) return;
    _document.closeFile();
    setState(() {
      _editMode = false;
      _singleGameFocus = false;
      _detectedTrophies = const [];
      _trophyGameIndex = -1;
    });
    if (_tabController.index != _kGameTab) _tabController.animateTo(_kGameTab);
    _reclaimFocus();
  }

  Future<String?> _chooseCopyDestination(
    BuildContext context, {
    String? name,
  }) => chooseViewerCopyDestination(context, _document, name: name);

  @override
  Future<bool> _savePgn() async {
    _pgnWidgetController.flushPendingComments();
    await showDocumentSaveDialog(
      context,
      title: AppLocalizations.of(context).documentCollectionSaveTitle,
      session: _document.editor,
      chooseCopyDestination: _chooseCopyDestination,
    );
    return !_document.editor.state.dirty && !_document.editor.state.uncertain;
  }

  Future<bool> _confirmLeavePgn() async {
    final navigation = _navigationRestoreEpoch;
    _pgnWidgetController.flushPendingComments();
    final editor = _document.editor;
    if (!editor.state.needsResolution) return true;
    if (editor.autoSave &&
        _document.filePath != null &&
        !editor.needsSaveRecovery) {
      await editor.flushPendingMetadata();
      if (!_isCurrentNavigation(navigation)) return false;
      _pgnWidgetController.flushPendingComments();
      if (!editor.state.needsResolution) return true;
    }
    if (!mounted || !_isCurrentNavigation(navigation)) return false;
    final choice = await showDocumentLeaveDialog(
      context,
      session: editor,
      revision: () => widget.lifetime.closeRevision,
      chooseCopyDestination: _chooseCopyDestination,
    );
    if (!_isCurrentNavigation(navigation) ||
        choice == null ||
        choice.revision != widget.lifetime.closeRevision) {
      return false;
    }
    if (choice.discard) editor.discardChanges();
    return true;
  }

  void _showPendingSliceRestoreSnackBar() {
    final info = _document.filters.pendingRestore;
    if (info == null || !mounted) return;
    _document.filters.clearPendingRestore();
    showAppSnackBar(
      context,
      'Restored last slice (${info.filteredCount}/${info.totalCount} games)',
      actionLabel: 'Show All',
      onAction: _document.resetFilters,
    );
  }

  @override
  void _openSliceDialog() => _showPanel(PgnWorkspace.filters);

  @override
  Widget _buildFilterWorkspace() {
    final source = _document.collection.games;
    final revision = _document.collection.contentRevision;
    if (!identical(source, _filterSource) ||
        _filterRevision != _document.collection.contentRevision) {
      _filterSource = source;
      _filterRevision = _document.collection.contentRevision;
      _filterRecords = source
          .map(
            (game) => (
              headers: Map<String, String>.of(game.headers),
              pgnText: game.pgnText,
            ),
          )
          .toList();
    }
    return PgnGameFilterWorkspace(
      matcher: _document.collectionFilter,
      key: ObjectKey(source),
      collectionName: _document.filePath == null
          ? (_document.collectionTitle ?? 'Pasted games')
          : p.basename(_document.filePath!),
      allGames: _filterRecords,
      collectionPlayer: _document.collection.collectionPlayer,
      currentFen:
          _filterOriginFen ??
          normalizeFen(_document.reading.currentPosition.fen),
      initialConfig: _document.filters.selection.config,
      fenIndex: _document.positionIndexController.value,
      onApply: (indices, config) {
        if (!mounted ||
            !identical(source, _document.collection.games) ||
            revision != _document.collection.contentRevision) {
          return;
        }
        _filterReturnSource = null;
        _document.applySlice(indices, config);
        _showPanel(PgnWorkspace.game);
      },
      onOpenGame: (indices, config, gameIndex) {
        if (!mounted ||
            !identical(source, _document.collection.games) ||
            revision != _document.collection.contentRevision) {
          return;
        }
        _filterReturnSource = source;
        _document.applySlice(indices, config);
        _document.reading.goToGame(
          _document.collection.visibleGames.indexOf(source[gameIndex]),
        );
        _showPanel(PgnWorkspace.game);
      },
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
    final games = _document.collection.visibleGames;
    final index = _document.collection.selectedIndex;
    // Keyed by game identity, not index: applying or clearing a slice resets
    // the index to 0 with a different game there, and an index-based key
    // would keep the previous game's banner.
    final key = games.isEmpty || index >= games.length
        ? null
        : '${_document.filePath}'
              '#${dedupKeyForHeaders(games[index].headers, pgn: games[index].pgnText)}';
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
    final games = _document.collection.visibleGames;
    if (games.isEmpty) return;
    final entry = games[_document.collection.selectedIndex];
    final meWhite = _myColorIn(entry.headers);
    if (meWhite == null) return;
    final report = await GameDeviationService.instance.analyzeGame(
      gameSans: mainlineSansOf(entry.pgnText),
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
  @override
  Position? _gamePanePosition;
  Position? _bookPanePosition;

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
    final key = '${_document.filePath}#${entry.label}#${entry.pgnText.length}';
    if (key != _lineSansKey) {
      _lineSansKey = key;
      _lineSans = mainlineSansOf(entry.pgnText);
    }
    return _lineSans;
  }

  @override
  void _onGamePosition(Position position) {
    if (!mounted) return;
    _document.reading.rememberReadingPosition();
    _gamePanePosition = position;
    if (_document.presentation.isFullScreen) setState(() {});
    // TabBarView keeps the Game child alive while Book is visible. Engine or
    // async widget updates from that hidden child must not steal the board.
    if (!_onLineTab &&
        _tabController.index != PgnWorkspace.filters &&
        !_document.reading.tree.showOpeningTree) {
      _document.reading.onPositionChanged(position);
    }
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
    if (_document.reading.solitaire.isActive || !_lineTabVisible) return;
    if (!_lineTabVisited) setState(() => _lineTabVisited = true);
    _tabController.animateTo(_lineTabIndex);
  }

  @override
  void _setExplorerHover(ExplorerMove? move) {
    if (identical(move, _explorerHoverMove)) return;
    setState(() => _explorerHoverMove = move);
  }

  /// A game the explorer listed: fetch it, file it in the explorer
  /// collection, and hand the viewer over to it at the position we were
  /// looking at.  A hand-off rather than a load-in-place, so the breadcrumb
  /// trail remembers the game you came from.
  @override
  Future<void> _openExplorerGame(ExplorerGame game) async {
    final fen = _document.reading.currentPosition.fen;
    final opened = await _gameOpener.open(game, fen: fen);
    if (!mounted) return;
    if (opened == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not fetch that game.')),
      );
      return;
    }
    _explorerHoverMove = null;
    context.read<AppState>().switchToPgnViewer(
      path: opened.path,
      gameIndex: opened.index,
      ply: opened.ply,
      tab: PgnViewerTab.explorer,
      historyLabel: 'Game: ${opened.label}',
    );
  }

  /// A book-line move was selected on the Line tab — put it on the main board.
  /// The tab that has focus owns the board, which is what makes flipping
  /// between Game and Line a comparison rather than two separate viewers.
  @override
  void _showLinePosition(Position position) {
    if (!mounted) return;
    _bookPanePosition = position;
    if (_tabController.index != _lineTabIndex) return;
    _document.reading.onPositionChanged(position);
  }

  /// Runs after full-game analysis: every solitaire guess the user tried and
  /// had rejected is evaluated and compared to the move actually played.
  ///
  /// Solitaire itself can't do this — it only knows *whether* a guess matched,
  /// not whether it was better — and full-game analysis only evaluates moves
  /// that were played, so the comparison needs both halves together.
  @override
  Future<void> _detectTrophies() async {
    final pool = context.read<StockfishPool>();
    final guesses = _document.reading.solitaire.controller.guessLog;
    if (guesses.isEmpty || _document.collection.visibleGames.isEmpty) return;

    final game =
        _document.collection.visibleGames[_document.collection.selectedIndex];
    try {
      final found = await detectSolitaireTrophies(
        pool: pool,
        guesses: guesses,
        evals: _analysisController.evals,
        userIsWhite: _document.reading.solitaire.controller.userIsWhite,
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
        _trophyGameIndex = _document.collection.selectedIndex;
      });
      _document.reading.solitaire.noteTrophiesEarned(found.length);
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

  void _showTrophyCabinet() {
    unawaited(
      showDialog(
        context: context,
        builder: (_) => SolitaireTrophyCabinet(onOpenGame: _openTrophyPosition),
      ).then((_) {
        unawaited(_document.reading.loadSolitaireSettings());
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
    final loaded = await _document.loadPgnContent(
      trophy.pgn,
      initialFen: trophy.fen,
    );
    if (!mounted) return;
    final error = _document.errorMessage ?? _document.editor.errorMessage;
    if (!loaded && error != null) {
      showAppSnackBar(
        context,
        error,
        isError: true,
        duration: const Duration(seconds: 4),
      );
    }
  }

  /// Leave a running solitaire session — asking first when guesses made so
  /// far would be thrown away — or close the setup strip.
  @override
  Future<void> _leaveSolitaire() async {
    if (!_document.reading.solitaire.isActive) {
      _document.reading.solitaire.cancelSetup();
      _reclaimFocus();
      return;
    }
    if (_document.reading.solitaire.controller.hasProgress) {
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
    _document.reading.solitaire.stop();
    _reclaimFocus();
  }

  /// Run [action] (switching game) — after asking, when a solitaire game is
  /// half done.
  @override
  Future<void> _guardingSolitaireProgress(VoidCallback action) async {
    if (_document.reading.solitaire.isActive &&
        _document.reading.solitaire.controller.hasProgress) {
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
    _document.reading.solitaire.stop();
    final cached =
        _analysisController.evals.isNotEmpty &&
        !_analysisController.isAnalyzing;
    _startAutoAnalysisForCurrentGame();
    if (cached) unawaited(_detectTrophies());
  }

  @override
  Future<void> _copyCurrentGamePgn({bool mainlineOnly = false}) async {
    if (_document.collection.visibleGames.isEmpty) return;
    final pgnText = _document
        .collection
        .visibleGames[_document.collection.selectedIndex]
        .pgnText;
    await Clipboard.setData(
      ClipboardData(
        text: mainlineOnly ? mainlinePgnWithoutComments(pgnText) : pgnText,
      ),
    );
    if (!mounted) return;
    showAppSnackBar(context, AppMessages.pgnCopied);
    _reclaimFocus();
  }

  @override
  Future<void> _copyCurrentFen() async {
    if (_document.collection.visibleGames.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: _document.reading.currentPosition.fen),
    );
    if (!mounted) return;
    showAppSnackBar(context, AppMessages.fenCopied);
    _reclaimFocus();
  }

  @override
  Future<void> _addCurrentGameToStudy() async {
    await addGamesToStudy(
      context,
      games: _document.collection.visibleGames,
      currentIndex: _document.collection.selectedIndex,
    );
    _reclaimFocus();
  }

  @override
  Future<void> _exportSlice() async {
    if (_document.collection.visibleGames.isEmpty) return;
    _pgnWidgetController.flushPendingComments();
    final session = DocumentSaveSession.draft(
      _document.collectionRepository,
      path: '',
      content: _document.buildExportContent(),
    );
    try {
      await showDocumentSaveDialog(
        context,
        title: AppLocalizations.of(context).documentExportTitle,
        session: session,
        chooseCopyDestination: (context) => _chooseCopyDestination(
          context,
          name: _document.defaultExportFileName() ?? 'games.pgn',
        ),
      );
      final destination = session.state.baseline?.path;
      if (mounted && destination != null) {
        showAppSnackBar(
          context,
          AppLocalizations.of(
            context,
          ).documentExported(p.basename(destination)),
          actionLabel: AppLocalizations.of(context).documentOpenExport,
          onAction: () => _loadFile(destination),
        );
      }
    } finally {
      await session.dispose();
    }
    if (mounted) _reclaimFocus();
  }

  /// Write the filtered games as a Scid v5 database.
  ///
  /// PGN stays the default export because everything reads it; this is for
  /// people who live in Scid, where the three-file database is what opens
  /// directly and indexes instantly. Scid vs. PC — a fork that split before
  /// this format existed — cannot read it, which the menu hint says.
  @override
  Future<void> _exportSliceAsScid() async {
    final games = _document.collection.visibleGames;
    if (games.isEmpty) return;

    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where should the Scid database go?',
      initialDirectory: _document.filePath == null
          ? null
          : p.dirname(_document.filePath!),
    );
    if (dir == null) {
      _reclaimFocus();
      return;
    }
    if (!mounted) return;

    final suggested = (_document.defaultExportFileName() ?? 'games').replaceAll(
      RegExp(r'\.pgn$'),
      '',
    );
    final name = await showNameEntryDialog(
      context,
      title: 'Name the database',
      fieldLabel: 'Database name',
      prompt:
          'Scid stores a database as three files sharing one name: '
          '.si5, .sg5 and .sn5.',
      initialValue: suggested,
      confirmLabel: 'Export',
    );
    if (name == null || !mounted) {
      _reclaimFocus();
      return;
    }

    final texts = [for (final g in games) g.pgnText];
    final progress = ValueNotifier<String>('Preparing ${texts.length} games…');
    var dialogOpen = true;
    void closeProgress() {
      if (!dialogOpen) return;
      dialogOpen = false;
      if (mounted) Navigator.of(context).pop();
    }

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, message, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final result = await ScidWriter.write(
        directory: dir,
        name: name,
        games: _parsedGameStream(texts),
        description: 'Exported from Chess Auto Prep',
        total: texts.length,
        // Per game would be one notifier notification per game; the writer
        // calls this from inside its own `await for`.
        onProgress: (done, total) {
          if (done % _scidProgressEvery != 0 && done != total) return;
          progress.value = 'Wrote $done of ${total ?? texts.length} games…';
        },
      );
      closeProgress();
      if (!mounted) return;

      final parts = <String>['${result.games} games'];
      if (result.truncated.isNotEmpty) {
        parts.add('${result.truncated.length} cut short at an illegal move');
      }
      if (result.skipped.isNotEmpty) {
        parts.add('${result.skipped.length} skipped');
      }
      showAppSnackBar(
        context,
        'Wrote $name.si5 — ${parts.join(', ')}',
        duration: const Duration(seconds: 6),
        actionLabel: 'Show',
        onAction: () => unawaited(openInFileManager(result.indexPath)),
      );
    } catch (e) {
      closeProgress();
      if (!mounted) return;
      showAppSnackBar(context, 'Scid export failed: $e', isError: true);
    } finally {
      progress.dispose();
    }
    _reclaimFocus();
  }

  /// Games written between breaths, and progress updates between rebuilds.
  static const int _scidYieldEvery = 25;
  static const int _scidProgressEvery = 50;

  /// One parsed game at a time, straight from each game's own PGN text.
  ///
  /// The export used to join every filtered game into a single string and
  /// hand the whole thing to [PgnGame.parseMultiGamePgn], which replays every
  /// move of every game before the writer had seen one — so a several-thousand
  /// game database sat in memory three times over (the join, the parse tree,
  /// and the list the stream held alive) and the UI was frozen for all of it.
  /// [ScidWriter] consumes this with `await for`, so a lazy stream means one
  /// parsed game alive at a time, and the join is gone: `buildExportContent`
  /// only ever concatenated these same strings.
  ///
  /// The parse is still on this isolate — the pause every [_scidYieldEvery]
  /// games is what lets the progress dialog paint rather than making the work
  /// cheaper.
  static Stream<PgnGame<PgnNodeData>> _parsedGameStream(
    List<String> pgnTexts,
  ) async* {
    for (var i = 0; i < pgnTexts.length; i++) {
      yield parsePgnGame(pgnTexts[i]);
      if (i % _scidYieldEvery == _scidYieldEvery - 1) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  @override
  void _toggleEditMode() {
    if (!mounted) return;
    _pgnWidgetController.flushPendingComments();
    _showPanel(PgnWorkspace.game);
    setState(() => _editMode = !_editMode);
  }

  /// The Browse↔Edit toggle. A study file reopens in Study mode on the
  /// same chapter and position; any other collection offers the safe path —
  /// copy the current game into a study and edit it there. (In-place study
  /// editing of a shared collection is deliberately not offered: Study
  /// autosave rewrites the whole file, which a games cache can't tolerate.)
  @override
  Future<void> _editInStudy() async {
    final games = _document.collection.visibleGames;
    if (games.isEmpty) return;
    final path = _document.filePath;
    final game = games[_document.collection.selectedIndex];

    final played = _pgnWidgetController.mainLineIndex;
    final sanLine = played <= 0
        ? null
        : _pgnWidgetController.mainLineMoves.take(played).toList();

    if (path != null && await _isStudyPath(path)) {
      final indexInFile = _document.collection.games.indexOf(game);
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
      openAfterAdding: true,
      buildPgn: (_) => game.pgnText,
      viewSanLine: sanLine,
    );
    _reclaimFocus();
  }

  Future<bool> _isStudyPath(String path) async {
    final dir = await AppPaths.studiesDirectory();
    return p.isWithin(dir.path, path);
  }

  Future<void> _openGameSearch() async {
    if (_document.reading.tree.showOpeningTree) {
      await openTreePositionGameSearch(
        context: context,
        games: [
          for (final i in _document.reading.tree.gamesAtTreePosition())
            _document.collection.visibleGames[i],
        ],
        currentIndex: _document.reading.tree.gamesAtTreePosition().indexOf(
          _document.collection.selectedIndex,
        ),
        onSelected: (game) {
          if (!mounted) return;
          final index = _document.collection.visibleGames.indexOf(game);
          if (index >= 0) _document.reading.loadGameFromTree(index);
        },
      );
      _reclaimFocus();
      return;
    }
    if (_document.collection.visibleGames.isEmpty) return;
    final selected = await showGameSearchDialog(
      context: context,
      games: [
        for (final g in _document.collection.visibleGames)
          GameNavItem.fromEntry(g),
      ],
      currentIndex: _document.collection.selectedIndex,
    );
    if (selected != null) _document.reading.goToGame(selected);
    _reclaimFocus();
  }

  /// Whether the Book tab is the one on screen (and so owns the board and the
  /// arrow keys).
  @override
  bool get _onLineTab =>
      !_document.reading.solitaire.isActive &&
      _tabController.index == _lineTabIndex;

  /// The one movetext surface the user can currently see. Keep active-pane
  /// dispatch centralized here so a new command cannot accidentally mutate
  /// the reader behind the selected tab.
  @override
  PgnViewerHandle get _activeMovetextController =>
      _movementReader ?? _pgnWidgetController;

  @override
  void _handleBoardMove(String san) {
    if (_tabController.index == PgnWorkspace.filters) {
      final next = playSanOrNullMove(_document.reading.currentPosition, san);
      if (next != null) {
        _filterOriginFen = next.fen;
        _document.reading.onPositionChanged(next);
      }
      return;
    }
    _document.reading.onBoardMove(san, reader: _movementReader);
  }

  /// The viewer's keyboard shortcuts, dispatched through [handleKeyBindings]
  /// (never while typing). Order matters: the solitaire block shadows keys
  /// that would disturb a puzzle. Keep descriptions in sync with the button
  /// tooltips that advertise them.
  List<KeyBinding> get _keyBindings => [
    if (!_document.reading.solitaire.isConfiguring)
      ...KeyBinding.forShortcutIf(
        AppShortcut.focusVariation,
        'Focus current variation',
        () {
          final reader = _activeMovetextController;
          return reader is PgnViewerWidgetController && reader.focusVariation();
        },
      ),
    // Solitaire: arrows/Home/End still browse the revealed region (the PGN
    // widget caps mainline navigation at the frontier); R reveals, and the
    // autoplay/tab-switch/engine/amend keys are swallowed so they can't
    // disturb the puzzle.
    if (_document.reading.solitaire.isActive) ...[
      // preempts: solitaire deliberately shadows the normal meaning of these
      // keys — R stops being "return to mainline", and the four below stop
      // doing anything at all. Saying so here is what keeps the dead-binding
      // check from flagging the ones underneath.
      ...KeyBinding.forShortcut(
        AppShortcut.revealMove,
        'Reveal current move',
        () {
          if (_document.reading.solitaire.controller.canReveal)
            _document.reading.solitaire.revealCurrentMove();
        },
        preempts: true,
      ),
      ...KeyBinding.forShortcut(
        AppShortcut.hintMove,
        'Hint: highlight the piece that moves',
        _document.reading.solitaire.hintCurrentMove,
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
      () => _document.reading.navigateBack(reader: _movementReader),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.forwardOneMove,
      'Forward one move',
      () => _document.reading.navigateForward(reader: _movementReader),
      repeats: true,
    ),
    // Home/End and PageUp/PageDown both jump to the ends of the line: the
    // viewer's own buttons advertise Home/End, and the page keys are what a
    // hand already on the arrow cluster reaches for.
    ...KeyBinding.forShortcut(
      AppShortcut.goToStart,
      'Go to start of line',
      () => _document.reading.navigateToStart(reader: _movementReader),
    ),

    ...KeyBinding.forShortcut(
      AppShortcut.goToEnd,
      'Go to end of line',
      () => _document.reading.navigateToEnd(reader: _movementReader),
    ),

    // In the PGN reader, the four arrow keys form one spatial model: left /
    // right move within a line, up / down move between chapters. Letter
    // aliases made the simple model harder to learn, so this screen does not
    // inherit the app-wide P/S alternatives.
    ...KeyBinding.forShortcut(
      AppShortcut.nextItem,
      'Next game',
      _document.reading.nextGame,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.previousItem,
      'Previous game',
      _document.reading.prevGame,
      repeats: true,
    ),
    if (!_onLineTab)
      ...KeyBinding.forShortcut(
        AppShortcut.fullScreen,
        'Toggle fullscreen',
        _document.presentation.toggleFullScreen,
      ),
    ...KeyBinding.forShortcut(
      AppShortcut.flipBoard,
      'Flip board',
      _document.presentation.toggleBoardFlipped,
    ),
    ...KeyBinding.forShortcut(AppShortcut.pastePgn, 'Paste PGN', _pastePgn),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleEngine,
      'Toggle engine',
      _toggleEngine,
    ),
    if (!_onLineTab) ...[
      ...KeyBinding.forShortcut(
        AppShortcut.autoPlay,
        'Toggle auto-play',
        _document.reading.toggleAutoPlay,
      ),
      ...KeyBinding.forShortcut(
        AppShortcut.autoNextGame,
        'Toggle auto next game',
        () => _document.reading.playback.setAutoNextGame(
          !_document.reading.playback.autoNextGame,
        ),
      ),
      ...KeyBinding.forShortcut(
        AppShortcut.amendGame,
        'Edit in Study',
        _editInStudy,
      ),
    ],
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
    if (_document.reading.solitaire.isConfiguring)
      ...KeyBinding.forShortcutIf(
        AppShortcut.startSolitaire,
        'Start solitaire',
        () {
          _document.reading.solitaire.begin();
          return true;
        },
      ),
    // Escape leaves whatever you are in, innermost first — the ordering is the
    // whole contract: solitaire and amend are modes you entered, full screen is
    // a view you entered, and scratch analysis moves are the only thing left to
    // back out of once you are in none of them. Leaving a half-played
    // solitaire game asks first.
    ...KeyBinding.forShortcut(
      AppShortcut.leave,
      'Exit solitaire / edit / fullscreen, clear analysis moves',
      () {
        if (_activeMovetextController
            case final PgnViewerWidgetController reader) {
          if (reader.returnToReadingMove() || reader.returnToParentLine()) {
            return;
          }
        }
        if (_document.reading.solitaire.isActive ||
            _document.reading.solitaire.isConfiguring) {
          unawaited(_leaveSolitaire());
        } else if (_editMode) {
          _toggleEditMode();
        } else if (_document.presentation.isFullScreen) {
          unawaited(_document.presentation.exitFullScreen());
        } else {
          _activeMovetextController.clearEphemeralMoves();
        }
      },
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.nextTab,
      'Next tab',
      _tabController.next,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.returnToMainline,
      'Return to mainline',
      () {
        if (_activeMovetextController.inVariation) {
          _activeMovetextController.returnToMainline();
        }
      },
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
    if (_document.reading.tree.showOpeningTree) return true;
    if (_document.reading.solitaire.isActive) {
      unawaited(_leaveSolitaire());
    } else {
      _document.reading.solitaire.toggle();
      // The setup strip and the game itself live in the Game tab; opening
      // setup from Analysis or Line would otherwise light the icon and show
      // nothing.
      if (_document.reading.solitaire.isConfiguring)
        _tabController.animateTo(_kGameTab);
    }
    return true;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) =>
      !_document.presentation.isFullScreen &&
          _tabController.index == PgnWorkspace.filters
      ? KeyEventResult.ignored
      : handleKeyBindings(_keyBindings, event, node: node);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final content = Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reclaimFocus,
        child: Stack(
          children: [
            Visibility(
              visible: !_document.presentation.isFullScreen,
              maintainState: true,
              child: Scaffold(
                appBar: _buildAppBar(theme),
                body: Stack(
                  children: [
                    ResponsiveSplitLayout(
                      breakpoint: kCompactBreakpoint,
                      primary: _buildBoardPane(),
                      secondary: _buildSidePanel(),
                    ),
                    if (_document.isPreparingCollection)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Tooltip(
                          message:
                              'Preparing opening filters and position search',
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      ),
                    if (_document.isLoading)
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
            if (_document.presentation.isFullScreen)
              _buildFullScreenView(theme),
          ],
        ),
      ),
    );
    return content;
  }
}
