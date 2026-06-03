/// PGN Viewer mode — browse master game collections for study.
///
/// Features: file picker, position/header-based dataset slicing, game-by-game
/// navigation with counter, auto-play with configurable delay, 1-5 star game
/// rating (persisted as [StudyRating] PGN header, auto-saved), full-game
/// Stockfish analysis with eval graph, inline engine bar, and comment editing.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../core/pgn_viewer_controller.dart';
import '../services/game_analysis_controller.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/layout/responsive_split_layout.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/fullscreen_game_view.dart';
import '../widgets/game_analysis_tab.dart';
import '../widgets/game_nav_bar.dart';
import '../widgets/opening_tree_widget.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/pgn_slice_dialog.dart';

class PgnViewerScreen extends StatefulWidget {
  const PgnViewerScreen({super.key});

  @override
  State<PgnViewerScreen> createState() => _PgnViewerScreenState();
}

class _PgnViewerScreenState extends State<PgnViewerScreen>
    with TickerProviderStateMixin, WindowListener {
  late final PgnViewerController _controller;
  late final PgnViewerWidgetController _pgnWidgetController;
  late final GameAnalysisController _analysisController;
  late final TabController _tabController;
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnViewerScreen');

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().addListener(_onAppStateChanged);
      }
    });
  }

  void _onControllerUpdate() {
    if (mounted) setState(() {});
  }

  void _onAppStateChanged() {
    final appState = context.read<AppState>();
    if (appState.currentMode == AppMode.pgnViewer) {
      _reclaimFocus();
    }
  }

  void _onAnalysisUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _controller.removeListener(_onControllerUpdate);
    _controller.disposeController();
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

  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
      initialDirectory: _controller.pickFileInitialDirectory(),
    );
    if (result == null || result.files.single.path == null) return;
    await _loadFile(result.files.single.path!);
  }

  Future<void> _loadFile(String path) async {
    await _controller.loadFile(path);
    if (!mounted) return;
    final error = _controller.errorMessage;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }
    _showPendingSliceRestoreSnackBar();
  }

  void _showPendingSliceRestoreSnackBar() {
    final info = _controller.pendingSliceRestore;
    if (info == null || !mounted) return;
    _controller.clearPendingSliceRestore();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Restored last slice (${info.filteredCount}/${info.totalCount} games)'),
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: _controller.resetFilters,
      ),
    ));
  }

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
        onApply: (indices, config) {
          _controller.applySlice(indices, config);
        },
      ),
    ).then((_) => _reclaimFocus());
  }

  Future<void> _copyCurrentGamePgn() async {
    if (_controller.filteredGames.isEmpty) return;
    final pgnText =
        _controller.filteredGames[_controller.currentGameIndex].pgnText;
    await Clipboard.setData(ClipboardData(text: pgnText));
    if (!mounted) return;
    showAppSnackBar(context, AppMessages.pgnCopied);
    _reclaimFocus();
  }

  Future<void> _exportSlice() async {
    if (_controller.filteredGames.isEmpty || _controller.filePath == null) {
      return;
    }

    final defaultName = _controller.defaultExportFileName();
    if (defaultName == null) return;

    final outPath = await FilePicker.saveFile(
      dialogTitle: 'Export ${_controller.filteredGames.length} filtered games',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: ['pgn'],
      initialDirectory: p.dirname(_controller.filePath!),
    );
    if (outPath == null) {
      _reclaimFocus();
      return;
    }

    final savePath = await _controller.exportSliceToPath(outPath);
    if (!mounted) return;
    if (savePath != null) {
      final fileName = p.basename(savePath);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Exported ${_controller.filteredGames.length} games to $fileName'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => _loadFile(savePath),
        ),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export failed')),
      );
    }
    _reclaimFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null && primaryFocus.context != null) {
      final widget = primaryFocus.context!.widget;
      if (widget is EditableText) return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft) {
      _controller.stopAutoPlay();
      _pgnWidgetController.goBack();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _controller.stopAutoPlay();
      _pgnWidgetController.goForward();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.home) {
      _controller.stopAutoPlay();
      _pgnWidgetController.clearEphemeralMoves();
      _pgnWidgetController.jumpToMove(1, true);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.end) {
      _controller.stopAutoPlay();
      final len = _pgnWidgetController.mainLineLength;
      if (len > 0) {
        final moveNum = (len + 1) ~/ 2;
        final isWhite = len % 2 == 1;
        _pgnWidgetController.jumpToMove(moveNum, isWhite);
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyN) {
      _controller.nextGame();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyP) {
      _controller.prevGame();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.f11 ||
        (key == LogicalKeyboardKey.keyF &&
            HardwareKeyboard.instance.isControlPressed)) {
      _controller.toggleFullScreen();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyF) {
      _controller.toggleBoardFlipped();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyE &&
        HardwareKeyboard.instance.isControlPressed) {
      _exportSlice();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyE) {
      InlineEngineBar.toggleEngine();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.space) {
      _controller.toggleAutoPlay();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyW) {
      _controller.setAutoNextGame(!_controller.autoNextGame);
      return KeyEventResult.handled;
    } else if (digitKeys.containsKey(key)) {
      final star = digitKeys[key]!;
      final current = _controller.filteredGames.isNotEmpty
          ? _controller.filteredGames[_controller.currentGameIndex].studyRating
          : 0;
      _controller.setRating(current == star ? 0 : star);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      if (_controller.isFullScreen) {
        _controller.exitFullScreen();
      } else {
        _pgnWidgetController.clearEphemeralMoves();
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.tab) {
      _tabController
          .animateTo((_tabController.index + 1) % _tabController.length);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.keyT) {
      _controller.toggleOpeningTree();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showAnalysisNodeMenu(int nodeId, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    showMenu<String>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Delete variation'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'clear_all',
          child: Row(
            children: [
              Icon(Icons.clear_all, size: 18),
              SizedBox(width: 8),
              Text('Clear all analysis'),
            ],
          ),
        ),
      ],
    ).then((action) {
      if (action == 'delete') {
        _pgnWidgetController.deleteAnalysisNode(nodeId);
      } else if (action == 'clear_all') {
        _pgnWidgetController.clearEphemeralMoves();
      }
      _reclaimFocus();
    });
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
            : SafeArea(
                bottom: false,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        _buildTopBar(theme),
                        Expanded(
                          child: ResponsiveSplitLayout(
                            breakpoint: kCompactBreakpoint,
                            primary: _buildBoardPane(),
                            secondary: _buildSidePanel(),
                          ),
                        ),
                      ],
                    ),
                    if (_controller.isLoading)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black26,
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

  Widget _buildFullScreenView(ThemeData theme) {
    return FullscreenGameView(
      position: _controller.currentPosition,
      boardFlipped: _controller.boardFlipped,
      gameLabel: _controller.filteredGames.isNotEmpty
          ? _controller.filteredGames[_controller.currentGameIndex].label
          : '',
      currentIndex: _controller.currentGameIndex,
      totalGames: _controller.filteredGames.length,
      isAutoPlaying: _controller.isAutoPlaying,
      autoPlayDelaySec: _controller.autoPlayDelaySec,
      autoNextGame: _controller.autoNextGame,
      onBoardMove: (san) {
        _controller.stopAutoPlay();
        _pgnWidgetController.addEphemeralMove(san);
      },
      onPrev: _controller.prevGame,
      onNext: _controller.nextGame,
      onGoBack: () {
        _controller.stopAutoPlay();
        _pgnWidgetController.goBack();
      },
      onGoForward: () {
        _controller.stopAutoPlay();
        _pgnWidgetController.goForward();
      },
      onToggleAutoPlay: _controller.toggleAutoPlay,
      onExit: _controller.exitFullScreen,
      onSetSpeed: _controller.setAutoPlaySpeed,
      onSetAutoNext: _controller.setAutoNextGame,
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    final fileName = _controller.filePath != null
        ? p.basename(_controller.filePath!)
        : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Text('PGN Viewer', style: theme.textTheme.titleMedium),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(fileName.isEmpty ? 'Open PGN' : fileName),
          ),
          if (_controller.allGames.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(child: _buildSliceChips()),
          ] else
            const Spacer(),
          if (_controller.filteredGames.isNotEmpty) ...[
            IconButton(
              onPressed: _exportSlice,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Export filtered games (Ctrl+E)',
            ),
            IconButton(
              onPressed: _controller.toggleBoardFlipped,
              icon: const Icon(Icons.swap_vert, size: 20),
              tooltip: 'Flip board (F)',
            ),
            _buildPerspectiveButton(),
          ],
          const AppModeMenuButton(),
        ],
      ),
    );
  }

  Widget _buildSliceChips() {
    final chipLabels = _controller.activeSliceConfig.chipLabels;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < chipLabels.length; i++) ...[
            _buildActiveChip(chipLabels[i], i),
            const SizedBox(width: 4),
          ],
          _buildAddSliceChip(),
          if (_controller.hasActiveFilters) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: Colors.blue.withAlpha(60), width: 0.5),
              ),
              child: Text(
                '${_controller.filteredGames.length}/${_controller.allGames.length}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue[300],
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveChip(String label, int index) {
    return GestureDetector(
      onTap: _openSliceDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blue[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withAlpha(60), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue[100],
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _controller.removeSliceChip(index),
              child: Icon(Icons.close,
                  size: 13, color: Colors.blue[300]!.withAlpha(180)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddSliceChip() {
    return Tooltip(
      message: _controller.hasActiveFilters ? 'Edit filters' : 'Add filter',
      child: GestureDetector(
        onTap: _openSliceDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _controller.hasActiveFilters
                  ? Colors.blue.withAlpha(40)
                  : Colors.grey[700]!,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add,
                size: 13,
                color: _controller.hasActiveFilters
                    ? Colors.blue[300]
                    : Colors.grey[400],
              ),
              const SizedBox(width: 3),
              Text(
                _controller.hasActiveFilters ? 'Edit' : 'Slice',
                style: TextStyle(
                  fontSize: 11,
                  color: _controller.hasActiveFilters
                      ? Colors.blue[300]
                      : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPerspectiveButton() {
    final protagonist = _controller.detectProtagonist();
    final isPlayerMode =
        _controller.perspective.mode == PerspectiveMode.player;
    final isWhiteMode =
        _controller.perspective.mode == PerspectiveMode.white;
    final isBlackMode =
        _controller.perspective.mode == PerspectiveMode.black;

    final label = switch (_controller.perspective.mode) {
      PerspectiveMode.white => 'White',
      PerspectiveMode.black => 'Black',
      PerspectiveMode.player => _controller.perspective.playerName,
    };

    return PopupMenuButton<Perspective>(
      tooltip: 'Default view as',
      onSelected: _controller.setPerspective,
      itemBuilder: (ctx) => [
        if (protagonist != null)
          PopupMenuItem(
            value: Perspective(
                mode: PerspectiveMode.player, playerName: protagonist),
            child: Row(children: [
              if (isPlayerMode &&
                  _controller.perspective.playerName == protagonist)
                const Icon(Icons.check, size: 16)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(protagonist),
            ]),
          ),
        PopupMenuItem(
          value: const Perspective(mode: PerspectiveMode.white),
          child: Row(children: [
            if (isWhiteMode)
              const Icon(Icons.check, size: 16)
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            const Text('Always White'),
          ]),
        ),
        PopupMenuItem(
          value: const Perspective(mode: PerspectiveMode.black),
          child: Row(children: [
            if (isBlackMode)
              const Icon(Icons.check, size: 16)
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            const Text('Always Black'),
          ]),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _buildBoardPane() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: ChessBoardWidget(
            position: _controller.currentPosition,
            flipped: _controller.boardFlipped,
            onMove: (move) {
              _controller.stopAutoPlay();
              _pgnWidgetController.addEphemeralMove(move.san);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanel() {
    if (_controller.showOpeningTree) return _buildOpeningTreePanel();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                tabs: [
                  const Tab(text: 'Game'),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Analysis'),
                        if (_analysisController.isAnalyzing) ...[
                          const SizedBox(width: 6),
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_controller.filteredGames.isNotEmpty)
              Tooltip(
                message: 'Opening tree (T)',
                child: IconButton(
                  icon: Icon(Icons.account_tree,
                      size: 20, color: Colors.grey[400]),
                  onPressed: _controller.toggleOpeningTree,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildGameTab(),
              GameAnalysisTab(
                analysisController: _analysisController,
                pgnController: _pgnWidgetController,
                currentPly: _controller.currentPly,
                variationDepth: _pgnWidgetController.variationDepth,
                gamePgnText: _controller.filteredGames.isNotEmpty
                    ? _controller
                        .filteredGames[_controller.currentGameIndex].pgnText
                    : null,
                onAnnotatedMovetext: _controller.persistMoveComments,
                onUserNavigation: () {
                  _controller.stopAutoPlay();
                  _reclaimFocus();
                },
              ),
            ],
          ),
        ),
        if (_controller.filteredGames.isNotEmpty)
          GameNavBar(
            games: _controller.filteredGames
                .map((g) => GameNavItem(
                      label: g.label,
                      studyRating: g.studyRating,
                      studySummary: g.studySummary,
                      headers: g.headers,
                    ))
                .toList(),
            currentIndex: _controller.currentGameIndex,
            currentRating: _controller
                .filteredGames[_controller.currentGameIndex].studyRating,
            sortMode: _controller.sortMode,
            isAutoPlaying: _controller.isAutoPlaying,
            autoPlayDelaySec: _controller.autoPlayDelaySec,
            autoNextGame: _controller.autoNextGame,
            onPrev: _controller.prevGame,
            onNext: _controller.nextGame,
            onGoToGame: _controller.goToGame,
            onSetRating: _controller.setRating,
            onSetSortMode: _controller.setSortMode,
            onToggleAutoPlay: _controller.toggleAutoPlay,
            onToggleFullScreen: _controller.toggleFullScreen,
            onSetSpeed: _controller.setAutoPlaySpeed,
            onSetAutoNext: _controller.setAutoNextGame,
            onCopyPgn: _copyCurrentGamePgn,
            hasEphemeralAnnotations: _pgnWidgetController.hasEphemeralMoves,
            onClearAnnotations: () {
              _controller.stopAutoPlay();
              _pgnWidgetController.clearEphemeralMoves();
              setState(() {});
              _reclaimFocus();
            },
          ),
      ],
    );
  }

  Widget _buildOpeningTreePanel() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey[700]!),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: _controller.toggleOpeningTree,
                tooltip: 'Back to Game/Analysis (T)',
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Text(
                'Opening Tree',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.grey[200],
                ),
              ),
              const Spacer(),
              if (_controller.buildingTree)
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _controller.treeBuildTotal > 0
                              ? 'Building ${_controller.treeBuildProcessed} / ${_controller.treeBuildTotal}'
                              : 'Building tree...',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[400],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (_controller.buildingTree)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _controller.treeBuildTotal > 0
                        ? 'Building tree... ${_controller.treeBuildProcessed} / ${_controller.treeBuildTotal} games'
                        : 'Building tree...',
                    style: TextStyle(color: Colors.grey[300], fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (_controller.treeBuildTotal > 0)
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: _controller.treeBuildProcessed /
                            _controller.treeBuildTotal,
                      ),
                    ),
                ],
              ),
            ),
          )
        else if (_controller.openingTree == null)
          Expanded(
            child: Center(
              child: Text(
                'No tree available.\nLoad games to build.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500]),
              ),
            ),
          )
        else ...[
          Expanded(
            child: OpeningTreeWidget(
              tree: _controller.openingTree!,
              onMoveSelected: _controller.onTreeMoveSelected,
              onGoBack: _controller.onTreeGoBack,
              onGoForward: _controller.onTreeGoForward,
              currentMoveSequence: _controller.treeCurrentMoveSequence,
            ),
          ),
          _buildTreeGamesList(),
        ],
      ],
    );
  }

  Widget _buildTreeGamesList() {
    final matchingIndices = _controller.gamesAtTreePosition();
    if (matchingIndices.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey[700]!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              '${matchingIndices.length} game${matchingIndices.length == 1 ? '' : 's'} at this position',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[400],
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: matchingIndices.length,
              itemBuilder: (context, idx) {
                final gi = matchingIndices[idx];
                final game = _controller.filteredGames[gi];
                return InkWell(
                  onTap: () => _controller.loadGameFromTree(gi),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: Row(
                      children: [
                        Icon(Icons.play_arrow,
                            size: 14, color: Colors.blue[300]),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            game.label,
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (game.studyRating > 0) ...[
                          const Icon(Icons.star, size: 12, color: Colors.amber),
                          Text('${game.studyRating}',
                              style: const TextStyle(fontSize: 10)),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameTab() {
    if (_controller.filteredGames.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 16),
              Text(
                'No PGN loaded',
                style: TextStyle(color: Colors.grey[400], fontSize: 16),
              ),
              if (_controller.errorMessage != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _controller.errorMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _pickFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open PGN File'),
              ),
              if (_controller.recentFiles.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Recent',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (final path in _controller.recentFiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: InkWell(
                      onTap: () => _loadFile(path),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.grey[800]!),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.description,
                                size: 16, color: Colors.grey[500]),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                p.basename(path),
                                style: TextStyle(
                                  color: Colors.blue[300],
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    final game = _controller.filteredGames[_controller.currentGameIndex];
    return Column(
      children: [
        InlineEngineBar(
          fen: _controller.currentPosition.fen,
          onLineMoveTapped: _controller.onEngineLineMoveTapped,
          activeLineMoveIndex: _controller.activeEngineLineMoveIdx != null
              ? (_pgnWidgetController.variationDepth > 0
                  ? _pgnWidgetController.variationDepth - 1
                  : _controller.activeEngineLineMoveIdx)
              : null,
        ),
        const Divider(height: 1),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('game_${_controller.currentGameIndex}'),
            pgnText: game.pgnText,
            controller: _pgnWidgetController,
            onPositionChanged: _controller.onPositionChanged,
            onAnalysisNodeAction: _showAnalysisNodeMenu,
            onCommentsChanged: _controller.persistMoveComments,
          ),
        ),
      ],
    );
  }
}
