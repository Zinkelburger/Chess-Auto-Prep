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
import '../services/storage/storage_factory.dart';
import '../services/game_analysis_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/layout/responsive_split_layout.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/fullscreen_game_view.dart';
import '../widgets/game_analysis_tab.dart';
import '../widgets/game_nav_bar.dart';
import '../widgets/game_search_dialog.dart';
import '../widgets/pgn/generate_repertoire_dialog.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/pgn/pgn_opening_tree_panel.dart';
import '../widgets/pgn/pgn_perspective_button.dart';
import '../widgets/pgn/pgn_slice_chips.dart';
import '../widgets/pgn/solitaire_status_widgets.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/pgn_slice_dialog.dart';
import '../widgets/solitaire_trophy_cabinet.dart';
import 'puzzle_creator_screen.dart';

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
    if (mounted) setState(() {});
  }

  void _onAppStateChanged() {
    final appState = context.read<AppState>();
    if (appState.currentMode == AppMode.pgnViewer) {
      _consumePendingViewerFile(appState);
      _reclaimFocus();
    }
  }

  /// "Open Games in PGN Viewer" hook (Player Analysis): open the pending
  /// file and, when a FEN is given, slice to games containing that position.
  void _consumePendingViewerFile(AppState appState) {
    final path = appState.pendingPgnViewerPath;
    if (path == null) return;
    final sliceFen = appState.pendingPgnViewerSliceFen;
    appState.pendingPgnViewerPath = null;
    appState.pendingPgnViewerSliceFen = null;
    _openFileWithPositionSlice(path, sliceFen);
  }

  Future<void> _openFileWithPositionSlice(String path, String? sliceFen) async {
    // When a position slice is about to be applied it supersedes any restored
    // slice, so a "Restored last slice" notice would be misleading.
    await _loadFile(path, notifySliceRestore: sliceFen == null);
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
  Future<void> _loadFile(String path, {bool notifySliceRestore = true}) async {
    await _controller.loadFile(path);
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (isTextInputFocused()) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Solitaire: arrows/home/end browse the revealed region (the PGN widget
    // caps mainline navigation at the frontier); autoplay and tab-switching
    // stay disabled.
    if (_controller.isSolitaireMode) {
      // R reveals the current move once the reveal countdown has elapsed
      // (return-to-mainline's R is inert during solitaire).
      if (key == LogicalKeyboardKey.keyR && hasNoLetterModifiers) {
        if (_controller.solitaire.canReveal) _controller.revealCurrentMove();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.tab ||
          ((key == LogicalKeyboardKey.keyE || key == LogicalKeyboardKey.keyA) &&
              hasNoLetterModifiers)) {
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _controller.navigateBack();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _controller.navigateForward();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.home) {
      _controller.navigateToStart();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.end) {
      _controller.navigateToEnd();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyN && hasNoLetterModifiers) {
      _controller.nextGame();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyP && hasNoLetterModifiers) {
      _controller.prevGame();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.f11 ||
        (key == LogicalKeyboardKey.keyF &&
            HardwareKeyboard.instance.isControlPressed)) {
      _controller.toggleFullScreen();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyF && hasNoLetterModifiers) {
      _controller.toggleBoardFlipped();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyE &&
        HardwareKeyboard.instance.isControlPressed) {
      _exportSlice();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed) {
      _pastePgn();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyE && hasNoLetterModifiers) {
      InlineEngineBar.toggleEngine();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.space) {
      _controller.toggleAutoPlay();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyW && hasNoLetterModifiers) {
      _controller.setAutoNextGame(!_controller.autoNextGame);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyA && hasNoLetterModifiers) {
      _toggleEditMode();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyS && hasNoLetterModifiers) {
      _openGameSearch();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      if (_editMode) {
        _toggleEditMode();
      } else if (_controller.isFullScreen) {
        _controller.exitFullScreen();
      } else {
        _pgnWidgetController.clearEphemeralMoves();
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.tab) {
      _tabController.animateTo(
        (_tabController.index + 1) % _tabController.length,
      );
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyR && hasNoLetterModifiers) {
      if (_pgnWidgetController.inVariation) {
        _pgnWidgetController.returnToMainline();
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyT && hasNoLetterModifiers) {
      _controller.toggleOpeningTree();
      return KeyEventResult.handled;
    } else if (key.keyId >= LogicalKeyboardKey.digit1.keyId &&
        key.keyId <= LogicalKeyboardKey.digit9.keyId &&
        hasNoLetterModifiers) {
      // Play the numbered branch candidate shown in the fork bar.
      final index = key.keyId - LogicalKeyboardKey.digit1.keyId;
      if (_pgnWidgetController.selectBranchCandidate(index)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    } else if (key == LogicalKeyboardKey.keyS &&
        HardwareKeyboard.instance.isShiftPressed &&
        !isPrimaryModifierPressed) {
      if (!_controller.showOpeningTree) _controller.toggleSolitaire();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyC && hasNoLetterModifiers) {
      // Jump into the annotation panel's comment field (amend mode only).
      if (PgnAnnotationPanel.focusActive()) {
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

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
