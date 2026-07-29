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

import 'dart:convert';
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
import '../core/study_controller.dart';
import '../features/games/services/game_deviation_service.dart';
import '../features/games/services/game_moves.dart';
import '../features/games/services/my_repertoire_settings.dart';
import '../features/games/services/game_auto_analysis_service.dart';
import '../services/games_library/game_filter.dart' show dedupKeyForHeaders;
import '../services/lichess_auth_service.dart';
import '../services/storage/storage_factory.dart';
import '../services/game_analysis_controller.dart';
import '../models/solitaire_trophy.dart';
import '../services/solitaire_trophy_detector.dart';
import '../services/solitaire_trophy_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/engine/engine_gate.dart';
import '../widgets/jobs_status_button.dart';
import '../widgets/layout/responsive_split_layout.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/fullscreen_game_view.dart';
import '../widgets/game_analysis_tab.dart';
import '../widgets/game_nav_bar.dart';
import '../widgets/game_search_dialog.dart';
import '../widgets/info_hint.dart';
import '../widgets/pgn/add_to_study_dialog.dart';
import '../widgets/pgn/generate_repertoire_dialog.dart';
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
  @override
  late final GameAnalysisController _analysisController;
  @override
  late final TabController _tabController;
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnViewerScreen');

  @override
  bool _editMode = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _pgnWidgetController = PgnViewerWidgetController();
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
    // Tell the background auto-analysis job which game this screen shows, so
    // it never races the viewer's own analysis on the same game.
    GameAutoAnalysisService.instance.currentlyOpenGame = _currentGameDedupKey;
    windowManager.addListener(this);
    _controller.loadRecentFiles();
    _controller.loadCollections();
    _controller.loadSolitaireSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        appState.addListener(_onAppStateChanged);
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
    final appState = context.read<AppState>();
    if (appState.currentMode == AppMode.pgnViewer) {
      _consumePendingViewerFile(appState);
      _reclaimFocus();
    }
  }

  /// Handoff hook: open the pending file, then optionally slice to a
  /// position ("Open Games in PGN Viewer"), jump to one game and start the
  /// review ("Review" on the Games page).
  void _consumePendingViewerFile(AppState appState) {
    final handoff = appState.takeHandoff<OpenPgnViewer>();
    if (handoff == null) return;
    _openFromHandoff(handoff);
  }

  Future<void> _openFromHandoff(OpenPgnViewer handoff) async {
    final gameId = handoff.gameId;

    // Fast path: the requested game lives in the file that's already open
    // (Games page → Review → breadcrumb back → Review again). Reloading
    // would re-parse the whole games cache and — worse — cancel and forget
    // an analysis that is still running, so reuse the loaded collection.
    final sameFileLoaded =
        handoff.sliceFen == null &&
        gameId != null &&
        handoff.pgnPath == _controller.filePath &&
        _controller.errorMessage == null &&
        _controller.allGames.isNotEmpty;
    if (sameFileLoaded) {
      if (_currentGameIs(gameId)) {
        if (handoff.autoAnalyze && !_controller.isSolitaireMode) {
          _startAutoAnalysisForCurrentGame();
        }
        return;
      }
      if (await _goToGameById(gameId)) {
        if (!mounted) return;
        if (handoff.autoAnalyze && !_controller.isSolitaireMode) {
          _startAutoAnalysisForCurrentGame();
        }
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
      // all you asked for was one game.
      restoreSavedSlice: gameId == null,
    );
    if (!mounted ||
        _controller.errorMessage != null ||
        _controller.filePath != handoff.pgnPath) {
      return;
    }
    if (gameId != null) {
      final found = await _goToGameById(gameId);
      if (!found || !mounted) return;
    }
    // Solitaire hides the Analysis tab entirely; don't fight the mode.
    if (handoff.autoAnalyze && !_controller.isSolitaireMode) {
      _startAutoAnalysisForCurrentGame();
    }
  }

  /// Whether the currently displayed game is [gameId].
  bool _currentGameIs(String gameId) {
    final key = _currentGameDedupKey();
    return key != null && key == gameId;
  }

  /// Identity of the currently displayed game (also served to
  /// [GameAutoAnalysisService] so its job skips the game on screen).
  String? _currentGameDedupKey() {
    final games = _controller.filteredGames;
    if (games.isEmpty || _controller.currentGameIndex >= games.length) {
      return null;
    }
    return dedupKeyForHeaders(games[_controller.currentGameIndex].headers);
  }

  Future<bool> _goToGameById(String gameId) async {
    var index = _controller.filteredGames.indexWhere(
      (g) => dedupKeyForHeaders(g.headers) == gameId,
    );
    if (index < 0) {
      // A restored slice may hide the target game — widen to the whole file.
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
    _tabController.animateTo(1);
    if (_analysisController.isAnalyzing) return;
    if (_analysisController.evals.isNotEmpty) return;
    if (!EngineGate.ensureAvailable(context)) return;
    _analysisController.analyzeGame(
      _controller.filteredGames[_controller.currentGameIndex].pgnText,
      onAnnotatedMovetext: _controller.persistMoveComments,
      onComplete: _detectTrophies,
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

  @override
  void dispose() {
    windowManager.removeListener(this);
    GameAutoAnalysisService.instance.currentlyOpenGame = null;
    MyRepertoireSettings.instance.removeListener(
      _onRepertoireDesignationsChanged,
    );
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    _analysisController.removeListener(_onAnalysisUpdate);
    _analysisController.dispose();
    _tabController.dispose();
    _focusNode.dispose();
    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (_) {
      /* provider may already be disposed */
    }
    super.dispose();
  }

  @override
  void onWindowLeaveFullScreen() => _controller.onWindowLeaveFullScreen();

  @override
  void onWindowEnterFullScreen() => _controller.onWindowEnterFullScreen();

  @override
  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus && !isTextInputFocused()) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
      initialDirectory: _controller.pickFileInitialDirectory(),
    );
    if (result == null || result.files.single.path == null) return;
    await _loadFile(result.files.single.path!);
  }

  @override
  Future<void> _pastePgn() async {
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
    ).then((_) => _reclaimFocus());
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
    _computeDeviation(key);
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

  @override
  void _openDeviationInBuilder() {
    final report = _deviationReport;
    if (report == null) return;
    context.read<AppState>().switchToBuilder(
      repertoirePath: report.chapterPath,
      moveSequence: report.pathSans,
      historyLabel: 'Repertoire: ${report.chapterName}',
    );
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
    showDialog(
      context: context,
      builder: (_) => const SolitaireTrophyCabinet(),
    ).then((_) {
      _controller.loadSolitaireSettings();
      _reclaimFocus();
    });
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

    final result = await showDialog<AddToStudyResult>(
      context: context,
      builder: (_) => AddToStudyDialog(
        initialChapterName: suggested,
        title: 'Add game to study',
      ),
    );
    if (result == null || !mounted) {
      _reclaimFocus();
      return;
    }

    final study = context.read<StudyController>();
    final appState = context.read<AppState>();
    try {
      final path =
          result.existingPath ??
          await StorageFactory.instance.studyFilePath(result.newStudyName!);
      await study.addChapterToStudyFile(path, result.chapterName, pgn);
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Added "${result.chapterName}" to ${result.studyName}',
        actionLabel: 'Open',
        onAction: () async {
          await study.openStudy(path);
          study.selectChapter(study.doc.chapters.length - 1);
          appState.pushMode(
            AppMode.study,
            historyLabel: 'Study: ${result.studyName}',
          );
        },
      );
    } catch (e) {
      debugPrint('Add game to study failed: $e');
      if (mounted) {
        showAppSnackBar(context, 'Failed to add game to study.', isError: true);
      }
    }
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

  Future<void> _openGameSearch() async {
    if (_controller.filteredGames.isEmpty) return;
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => GameSearchDialog(
        games: _controller.filteredGames
            .map(
              (g) => GameNavItem(
                label: g.label,
                studyRating: g.studyRating,
                studySummary: g.studySummary,
                headers: g.headers,
              ),
            )
            .toList(),
        currentIndex: _controller.currentGameIndex,
      ),
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
      KeyBinding.run(LogicalKeyboardKey.keyR, 'Reveal current move', () {
        if (_controller.solitaire.canReveal) _controller.revealCurrentMove();
      }),
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyA,
      ])
        KeyBinding(key, 'Disabled during solitaire', () => true),
    ],
    KeyBinding.run(
      LogicalKeyboardKey.arrowLeft,
      'Back one move',
      _controller.navigateBack,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.arrowRight,
      'Forward one move',
      _controller.navigateForward,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.home,
      'Go to start',
      _controller.navigateToStart,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.end,
      'Go to end',
      _controller.navigateToEnd,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyN,
      'Next game',
      _controller.nextGame,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyP,
      'Previous game',
      _controller.prevGame,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.f11,
      'Toggle fullscreen',
      _controller.toggleFullScreen,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyF,
      'Toggle fullscreen',
      _controller.toggleFullScreen,
      control: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyF,
      'Flip board',
      _controller.toggleBoardFlipped,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyV,
      'Paste PGN',
      _pastePgn,
      control: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyE,
      'Toggle engine',
      InlineEngineBar.toggleEngine,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.space,
      'Toggle auto-play',
      _controller.toggleAutoPlay,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyW,
      'Toggle auto next game',
      () => _controller.setAutoNextGame(!_controller.autoNextGame),
    ),
    KeyBinding.run(
      LogicalKeyboardKey.keyA,
      'Toggle amend mode',
      _toggleEditMode,
    ),
    KeyBinding.run(LogicalKeyboardKey.keyS, 'Search games', _openGameSearch),
    KeyBinding.run(
      LogicalKeyboardKey.escape,
      'Exit amend mode / fullscreen, clear analysis moves',
      () {
        if (_editMode) {
          _toggleEditMode();
        } else if (_controller.isFullScreen) {
          _controller.exitFullScreen();
        } else {
          _pgnWidgetController.clearEphemeralMoves();
        }
      },
    ),
    KeyBinding.run(
      LogicalKeyboardKey.tab,
      'Next tab',
      () => _tabController.animateTo(
        (_tabController.index + 1) % _tabController.length,
      ),
    ),
    KeyBinding.run(LogicalKeyboardKey.keyR, 'Return to mainline', () {
      if (_pgnWidgetController.inVariation) {
        _pgnWidgetController.returnToMainline();
      }
    }),
    KeyBinding.run(
      LogicalKeyboardKey.keyT,
      'Toggle opening tree',
      _controller.toggleOpeningTree,
    ),
    // Play the numbered branch candidate shown in the fork bar.
    for (var i = 0; i < _digitKeys.length; i++)
      KeyBinding(
        _digitKeys[i],
        'Play fork candidate ${i + 1}',
        () => _pgnWidgetController.selectBranchCandidate(i),
      ),
    KeyBinding(LogicalKeyboardKey.keyS, 'Toggle solitaire mode', () {
      if (!_controller.showOpeningTree) _controller.toggleSolitaire();
      return true;
    }, shift: true),
    // Jump into the annotation panel's comment field (amend mode only).
    KeyBinding(
      LogicalKeyboardKey.keyC,
      'Comment current move',
      PgnAnnotationPanel.focusActive,
    ),
  ];

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) =>
      handleKeyBindings(_keyBindings, event);

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
