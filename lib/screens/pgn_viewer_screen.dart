/// PGN Viewer mode — browse master game collections for study.
///
/// Features: file picker, position/header-based dataset slicing, game-by-game
/// navigation with counter, auto-play with configurable delay, 1-5 star game
/// rating (persisted as [StudyRating] PGN header, auto-saved), full-game
/// Stockfish analysis with eval graph, inline engine bar, and comment editing.
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
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/pgn/pgn_opening_tree_panel.dart';
import '../widgets/pgn/pgn_perspective_button.dart';
import '../widgets/pgn/pgn_slice_chips.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/pgn_slice_dialog.dart';
import '../widgets/solitaire_trophy_cabinet.dart';

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
      if (mounted && _focusNode.canRequestFocus && !isTextInputFocused()) {
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

  Future<void> _loadFile(String path) async {
    await _controller.loadFile(path);
    if (!mounted) return;
    final error = _controller.errorMessage;
    if (error != null) {
      showAppSnackBar(context, error, duration: const Duration(seconds: 5));
      return;
    }
    _showPendingSliceRestoreSnackBar();
  }

  void _showPendingSliceRestoreSnackBar() {
    final info = _controller.pendingSliceRestore;
    if (info == null || !mounted) return;
    _controller.clearPendingSliceRestore();
    showAppSnackBar(
      context,
      'Restored last slice (${info.filteredCount}/${info.totalCount} games)',
      actionLabel: 'Undo',
      onAction: _controller.resetFilters,
    );
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
        fenIndex: _controller.fenIndex,
        presets: _controller.slicePresets,
        onApply: (indices, config) {
          _controller.applySlice(indices, config);
        },
      ),
    ).then((_) => _reclaimFocus());
  }

  void _showTrophyCabinet() {
    showDialog(
      context: context,
      builder: (_) => const SolitaireTrophyCabinet(),
    ).then((_) {
      _controller.loadSolitaireSettings();
      _reclaimFocus();
    });
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

  Future<void> _generateRepertoireFromGames() async {
    if (_controller.filteredGames.isEmpty) return;

    final storage = StorageFactory.instance;
    var suggestedName = _suggestRepertoireName();

    // Loop: show name dialog → check collision → resolve or retry.
    while (true) {
      final result = await showDialog<({String name, String color})>(
        context: context,
        builder: (ctx) =>
            _GenerateRepertoireDialog(suggestedName: suggestedName),
      );
      if (result == null || !mounted) {
        _reclaimFocus();
        return;
      }

      final safeName = result.name
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .trim();
      if (safeName.isEmpty) {
        showAppSnackBar(context, 'Invalid repertoire name.', isError: true);
        _reclaimFocus();
        return;
      }

      try {
        final repertoirePath = await storage.repertoireFilePath(safeName);

        if (await storage.fileExists(repertoirePath)) {
          if (!mounted) return;
          final action = await _showDuplicateNameDialog(safeName);
          if (!mounted) return;

          switch (action) {
            case _DuplicateNameAction.useExisting:
              await _seedExistingRepertoire(
                storage: storage,
                safeName: safeName,
                repertoirePath: repertoirePath,
              );
              _reclaimFocus();
              return;
            case _DuplicateNameAction.rename:
              suggestedName = safeName;
              continue; // re-show name dialog
            case _DuplicateNameAction.cancel:
            case null:
              _reclaimFocus();
              return;
          }
        }

        // New repertoire — write files and switch.
        final rawGamesName = '${safeName}_raw_games';
        final rawGamesPath = await storage.repertoireFilePath(rawGamesName);
        await storage.writeFile(
          rawGamesPath,
          _controller.buildExportContent(),
        );

        final header = '// $safeName Repertoire\n'
            '// Color: ${result.color}\n'
            '// Created on ${DateTime.now().toString().split('.')[0]}\n\n';
        await storage.writeFile(repertoirePath, header);

        if (!mounted) return;
        final gameCount = _controller.filteredGames.length;
        showAppSnackBar(
          context,
          'Created "$safeName" — switching to builder with $gameCount games.',
        );

        context.read<AppState>().switchToBuilderWithGeneration(
          repertoirePath: repertoirePath,
          pgnPaths: [rawGamesPath],
        );
        _reclaimFocus();
        return;
      } catch (e) {
        debugPrint('Generate repertoire from games failed: $e');
        if (mounted) {
          showAppSnackBar(context, 'Failed to create repertoire.',
              isError: true);
        }
        _reclaimFocus();
        return;
      }
    }
  }

  /// Overwrite the raw-games sidecar and open the existing repertoire in
  /// DB Explorer mode with auto-start.
  Future<void> _seedExistingRepertoire({
    required dynamic storage,
    required String safeName,
    required String repertoirePath,
  }) async {
    final rawGamesName = '${safeName}_raw_games';
    final rawGamesPath = await storage.repertoireFilePath(rawGamesName);
    await storage.writeFile(
      rawGamesPath,
      _controller.buildExportContent(),
    );

    if (!mounted) return;
    final gameCount = _controller.filteredGames.length;
    showAppSnackBar(
      context,
      'Updated seed for "$safeName" — switching to builder with $gameCount games.',
    );

    context.read<AppState>().switchToBuilderWithGeneration(
      repertoirePath: repertoirePath,
      pgnPaths: [rawGamesPath],
    );
  }

  Future<_DuplicateNameAction?> _showDuplicateNameDialog(String name) {
    return showDialog<_DuplicateNameAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Repertoire Already Exists'),
        content: Text(
          '"$name" already exists. You can update its game data '
          'and re-run generation, or pick a different name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DuplicateNameAction.cancel),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, _DuplicateNameAction.rename),
            child: const Text('Pick Different Name'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, _DuplicateNameAction.useExisting),
            child: const Text('Use Existing & Re-seed'),
          ),
        ],
      ),
    );
  }

  String _suggestRepertoireName() {
    final config = _controller.activeSliceConfig;
    final parts = <String>[];

    for (final filter in config.headerFilters) {
      if (filter.value.isNotEmpty &&
          (filter.field == 'White' || filter.field == 'Black')) {
        parts.add(filter.value);
      }
    }

    if (parts.isEmpty && _controller.filePath != null) {
      parts.add(p.basenameWithoutExtension(_controller.filePath!));
    }

    return parts.isEmpty ? 'My Repertoire' : parts.join(' ');
  }

  void _toggleEditMode() {
    setState(() => _editMode = !_editMode);
  }

  Future<void> _openGameSearch() async {
    if (_controller.filteredGames.isEmpty) return;
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => GameSearchDialog(
        games: _controller.filteredGames
            .map((g) => GameNavItem(
                  label: g.label,
                  studyRating: g.studyRating,
                  studySummary: g.studySummary,
                  headers: g.headers,
                ))
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
      _tabController
          .animateTo((_tabController.index + 1) % _tabController.length);
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

  PreferredSizeWidget _buildAppBar(ThemeData theme) {
    final fileName =
        _controller.filePath != null ? p.basename(_controller.filePath!) : '';
    return AppBar(
      titleSpacing: 16,
      leading: !_controller.showOpeningTree &&
              !_controller.isSolitaireMode &&
              _controller.hasTreeReturnPosition
          ? IconButton(
              onPressed: _controller.returnToTreePosition,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to opening-tree position',
            )
          : null,
      title: Row(
        children: [
          const Text('PGN Viewer'),
          const SizedBox(width: 12),
          Flexible(
            child: OutlinedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(
                fileName.isEmpty ? 'Open PGN' : fileName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _pastePgn,
            icon: const Icon(Icons.content_paste, size: 18),
            tooltip: 'Paste PGN from clipboard (Ctrl+V)',
            visualDensity: VisualDensity.compact,
          ),
          if (_controller.allGames.isNotEmpty &&
              !_controller.isSolitaireMode) ...[
            const SizedBox(width: 8),
            Expanded(
              child: PgnSliceChips(
                controller: _controller,
                onOpenSliceDialog: _openSliceDialog,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (_controller.filteredGames.isNotEmpty) ...[
          // Study modes: opening tree, amend, solitaire.
          if (!_controller.isSolitaireMode) ...[
            IconButton(
              onPressed: _controller.toggleOpeningTree,
              icon: Icon(
                Icons.account_tree,
                size: 20,
                color: _controller.showOpeningTree
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: 'Opening tree (T)',
            ),
            IconButton(
              onPressed: _toggleEditMode,
              icon: Icon(
                _editMode ? Icons.edit : Icons.edit_outlined,
                size: 20,
                color:
                    _editMode ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: 'Amend game — moves, marks & comments '
                  'are saved to the file (A)',
            ),
          ],
          IconButton(
            onPressed: _controller.showOpeningTree ? null : _controller.toggleSolitaire,
            icon: Icon(
              Icons.psychology,
              size: 20,
              color: _controller.isSolitaireMode
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: 'Solitaire mode (Shift+S)',
          ),
          if (_controller.isSolitaireMode &&
              _controller.totalTrophyCount > 0)
            IconButton(
              onPressed: () => _showTrophyCabinet(),
              icon: const Icon(Icons.emoji_events, size: 20, color: Colors.amber),
              tooltip: 'Trophies (${_controller.totalTrophyCount})',
            ),
          _actionDivider(),
          // Board view: flip, perspective.
          IconButton(
            onPressed: _controller.toggleBoardFlipped,
            icon: const Icon(Icons.swap_vert, size: 20),
            tooltip: 'Flip board (F)',
          ),
          if (!_controller.isSolitaireMode) ...[
            PgnPerspectiveButton(controller: _controller),
            _actionDivider(),
            // File / misc: export, overflow.
            IconButton(
              onPressed: _exportSlice,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Export filtered games (Ctrl+E)',
            ),
            PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'More actions',
            onSelected: (value) {
              if (value == 'generate_repertoire') {
                _generateRepertoireFromGames();
              } else if (value == 'trophies') {
                _showTrophyCabinet();
              } else if (value == 'make_puzzle') {
                context.read<AppState>().switchToPuzzleCreator(
                    seedFen: _controller.currentPosition.fen);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'make_puzzle',
                child: ListTile(
                  leading: Icon(Icons.extension, size: 20),
                  title: Text('Make puzzle from this position'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'generate_repertoire',
                child: ListTile(
                  leading: Icon(Icons.auto_fix_high, size: 20),
                  title: Text('Generate repertoire from games'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'trophies',
                child: ListTile(
                  leading: const Icon(Icons.emoji_events, size: 20, color: Colors.amber),
                  title: Text('Trophy cabinet (${_controller.totalTrophyCount})'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          ],
        ],
        const AppModeMenuButton(),
      ],
    );
  }

  /// Thin vertical separator between app-bar action groups.
  Widget _actionDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 22,
        child: VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildBoardPane() {
    final solitaire = _controller.solitaire;
    final showFeedback = _controller.isSolitaireMode && solitaire.feedback != null;

    return Container(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            children: [
              ChessBoardWidget(
                position: _controller.currentPosition,
                flipped: _controller.boardFlipped,
                onMove: (move) => _controller.onBoardMove(move.san),
                // In solitaire, moves are allowed while guessing and again
                // once the game completes (free exploration of the annotated
                // game); only opponent auto-play locks the board.
                enableUserMoves: !_controller.isSolitaireMode ||
                    solitaire.waitingForUser ||
                    solitaire.isComplete,
              ),
              // Only wrong guesses get an overlay; a correct guess just plays
              // out on the board (the green popup was noise).
              if (showFeedback &&
                  solitaire.feedback == SolitaireFeedback.incorrect)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Incorrect — try again',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
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


  Widget _buildSidePanel() {
    if (_controller.showOpeningTree) {
      return PgnOpeningTreePanel(controller: _controller);
    }
    // Solitaire is a pure guessing exercise: no Analysis tab (and no engine).
    final showTabs = !_controller.isSolitaireMode;
    return Column(
      children: [
        if (showTabs)
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
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.5),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        Expanded(
          child: showTabs
              ? TabBarView(
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
                              .filteredGames[_controller.currentGameIndex]
                              .pgnText
                          : null,
                      onAnnotatedMovetext: _controller.persistMoveComments,
                      onUserNavigation: () {
                        _controller.stopAutoPlay();
                        _reclaimFocus();
                      },
                    ),
                  ],
                )
              : _buildGameTab(),
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
            onToggleEditMode: _toggleEditMode,
            isEditMode: _editMode,
            isSolitaireMode: _controller.isSolitaireMode,
            solitaireWaitingForUser: _controller.isSolitaireMode &&
                _controller.solitaire.waitingForUser,
            solitaireCanReveal: _controller.isSolitaireMode &&
                _controller.solitaire.canReveal,
            solitaireRevealCountdown: _controller.isSolitaireMode
                ? _controller.solitaire.revealCountdownSec
                : 0,
            onReveal: _controller.revealCurrentMove,
            onExitSolitaire: _controller.toggleSolitaire,
          ),
      ],
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
        if (!_controller.isSolitaireMode)
          InlineEngineBar(
            fen: _controller.currentPosition.fen,
            onLineMoveTapped: _controller.onEngineLineMoveTapped,
          ),
        if (_controller.isSolitaireMode) _buildSolitaireStatusBar(),
        if (_controller.isSolitaireMode && _controller.solitaire.isComplete)
          _buildSolitaireCompleteBanner(),
        const Divider(height: 1),
        if (_editMode) _buildEditModeBar(),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('game_${_controller.currentGameIndex}'),
            pgnText: game.pgnText,
            controller: _pgnWidgetController,
            onPositionChanged: _controller.onPositionChanged,
            // Bound to this game object: the annotation panel debounces its
            // saves, which may flush after the user switches games.
            onCommentsChanged: (movetext) =>
                _controller.persistMoveCommentsFor(game, movetext),
            editMode: _editMode,
            revealedPly: _controller.isSolitaireMode
                ? _controller.solitaire.revealedPly
                : null,
          ),
        ),
      ],
    );
  }

  /// Compact end-of-game strip shown above the movetext instead of a modal
  /// overlay: the user is left freely browsing their fully annotated game.
  Widget _buildSolitaireCompleteBanner() {
    final s = _controller.solitaire;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.green.withValues(alpha: 0.12),
      child: Row(
        children: [
          const Icon(Icons.flag, size: 16, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Complete — ${s.correctFirstTry}/${s.totalUserMoves} first-try'
              '${s.revealedCount > 0 ? ', ${s.revealedCount} revealed' : ''}'
              '. Guess notes saved; browse and annotate freely.',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _controller.nextGame,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: const Text('Next game (N)'),
          ),
        ],
      ),
    );
  }

  Widget _buildSolitaireStatusBar() {
    final s = _controller.solitaire;
    final progress = s.totalMoves > 0
        ? s.revealedPly / s.totalMoves
        : 0.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(Icons.psychology, size: 16,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            'Solitaire (${s.userIsWhite ? "White" : "Black"})',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${s.revealedPly}/${s.totalMoves}',
            style: const TextStyle(fontSize: 12),
          ),
          if (s.totalUserMoves > 0) ...[
            const SizedBox(width: 8),
            Text(
              '${s.correctFirstTry}/${s.totalUserMoves} first-try',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
          const SizedBox(width: 4),
          _buildSolitaireSettingsButton(),
        ],
      ),
    );
  }

  Widget _buildSolitaireSettingsButton() {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 16,
          color: Theme.of(context).colorScheme.primary),
      tooltip: 'Solitaire settings',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.all(4),
      ),
      itemBuilder: (_) {
        final currentDelay = _controller.solitaire.revealDelaySec;
        return [
          const PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text('Reveal delay',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          for (final sec in [0, 15, 30, 60, 90, 120])
            PopupMenuItem(
              value: 'delay_$sec',
              height: 36,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: sec == currentDelay
                        ? Icon(Icons.check, size: 16,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    sec == 0 ? 'No delay' : '${sec}s',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
        ];
      },
      onSelected: (value) {
        if (value.startsWith('delay_')) {
          final sec = int.parse(value.substring(6));
          _controller.setSolitaireRevealDelay(sec);
        }
        _reclaimFocus();
      },
    );
  }

  Widget _buildEditModeBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: Colors.amber.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.edit, size: 14, color: Colors.amber[600]),
          const SizedBox(width: 6),
          Text(
            'Amending',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.amber[600],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Moves you play are saved to the file · '
              'click any move, then comment or glyph it below',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _toggleEditMode,
            icon: Icon(Icons.close, size: 14, color: Colors.grey[500]),
            label: Text(
              'Exit',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

enum _DuplicateNameAction { useExisting, rename, cancel }

class _GenerateRepertoireDialog extends StatefulWidget {
  final String suggestedName;
  const _GenerateRepertoireDialog({required this.suggestedName});

  @override
  State<_GenerateRepertoireDialog> createState() =>
      _GenerateRepertoireDialogState();
}

class _GenerateRepertoireDialogState extends State<_GenerateRepertoireDialog> {
  late final TextEditingController _nameCtrl;
  String _color = 'White';

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.suggestedName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Generate Repertoire from Games'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Repertoire name',
                hintText: 'e.g. Caruana Kan',
              ),
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            const Text('Color'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'White', label: Text('White')),
                ButtonSegment(value: 'Black', label: Text('Black')),
              ],
              selected: {_color},
              onSelectionChanged: (s) => setState(() => _color = s.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create & Generate'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name: name, color: _color));
  }
}
