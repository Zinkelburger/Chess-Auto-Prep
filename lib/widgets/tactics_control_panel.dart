import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartchess/dartchess.dart';

import '../core/app_state.dart';
import '../models/engine_settings.dart';
import '../models/tactics_session_settings.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/maia_factory.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics_database.dart';
import '../services/tactics_import_service.dart';
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import 'engine/inline_engine_bar.dart';
import 'pgn_viewer_widget.dart';
import 'pgn_with_engine.dart';
import 'tactics/tactics_browse_panel.dart';
import 'tactics/tactics_edit_dialog.dart';
import 'tactics/tactics_import_panel.dart';
import 'tactics/tactics_solution_navigator.dart';
import 'tactics/tactics_training_panel.dart';
import 'training/move_input_widget.dart';

class _ToggleInlineEngineIntent extends Intent {
  const _ToggleInlineEngineIntent();
}

/// Tactics training control panel with import, review, and analysis.
class TacticsControlPanel extends StatefulWidget {
  const TacticsControlPanel({super.key});

  /// Shared key for the tactics move-input widget so the `/` shortcut can
  /// focus it from the control panel.
  static final moveInputKey = GlobalKey<MoveInputWidgetState>();

  @override
  State<TacticsControlPanel> createState() => _TacticsControlPanelState();
}

class _TacticsControlPanelState extends State<TacticsControlPanel>
    with TickerProviderStateMixin {
  AppState? _appState;

  late TacticsDatabase _database;
  late TacticsSessionController _session;
  late TacticsImportCoordinator _import;

  late TabController _tabController;

  // Import controllers
  late TextEditingController _lichessUserController;
  late TextEditingController _lichessCountController;
  late TextEditingController _chessComUserController;
  late TextEditingController _stockfishDepthController;
  late TextEditingController _coresController;

  // Validation: _*Valid tracks logical state (immediate), _*Error is the
  // displayed red text (debounced so it doesn't flash while typing).
  bool _depthValid = true;
  bool _coresValid = true;
  String? _depthError;
  String? _coresError;
  Timer? _depthErrorTimer;
  Timer? _coresErrorTimer;

  // Fetch mode state
  TacticsImportMode _fetchMode = TacticsImportMode.recent;
  DateTime? _sinceDate;

  // PGN Viewer controller for analysis tab
  final PgnViewerWidgetController _pgnViewerController =
      PgnViewerWidgetController();

  /// Solution-line navigation (Show Solution board/PGN walking).
  late final TacticsSolutionNavigator _solutionNav;

  /// Tracks opponent-waiting state to detect when it's the user's turn again
  /// in multi-move puzzles (so we can refocus the move input).
  bool _wasWaitingForOpponent = false;

  // Focus node for keyboard shortcuts during training
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _database = TacticsDatabase();
    _session = TacticsSessionController(database: _database);
    _import = TacticsImportCoordinator(database: _database);
    _solutionNav = TacticsSolutionNavigator(
      pgn: _pgnViewerController,
      currentTactic: () => _session.currentPosition,
      solutionToSan: (tactic) => _session.engine.solutionLineToSan(tactic),
      syncPgnToTactic: _syncPgnToCurrentTactic,
      setBoardPosition: (position) =>
          context.read<AppState>().setCurrentPosition(position),
    );
    _session.onBoardUpdate = _applyBoardUpdate;
    _session.onPositionSetup = _loadPositionSetup;
    _session.addListener(_onSessionChanged);
    _import.addListener(_onImportChanged);
    _tabController = TabController(length: 2, vsync: this);

    _lichessUserController = TextEditingController();
    _lichessCountController = TextEditingController(text: '20');
    _chessComUserController = TextEditingController();
    _stockfishDepthController = TextEditingController(text: '15');
    final defaultCores = EngineSettings().workers;
    _coresController = TextEditingController(text: '$defaultCores');

    // Initialize controllers from AppState and reset board
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = _appState ?? context.read<AppState>();
        _lichessUserController.text = appState.lichessUsername ?? '';
        _chessComUserController.text = appState.chesscomUsername ?? '';

        appState.setMoveAttemptedCallback(_onMoveAttempted);
        _resetBoardToStart();
      }
    });

    // Listen for tab changes to enter/exit analysis mode
    _tabController.addListener(() {
      if (mounted) {
        final appState = context.read<AppState>();
        if (_tabController.index == 1) {
          appState.enterAnalysisMode();
          _focusNode.requestFocus();
        } else {
          appState.exitAnalysisMode();
        }
      }
    });

    // Auto-load positions on startup
    _loadPositions();

    // Pre-warm Stockfish pool + Maia so imports start instantly.
    _warmUpEngines();
  }

  /// Fire-and-forget: spawn Stockfish workers and load the Maia ONNX model
  /// while the user is still looking at the import form.
  Future<void> _warmUpEngines() async {
    final pool = StockfishPool();
    final targetWorkers = EngineSettings().workers;
    await pool.ensureWorkers(targetWorkers);
    // Maia init is cheap after the first call (singleton).
    if (MaiaFactory.isAvailable) {
      try {
        await MaiaFactory.instance?.initialize();
      } catch (_) {
        // Best-effort; failure here is non-fatal and intentionally ignored.
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState ??= context.read<AppState>();
  }

  void _onSessionChanged() {
    if (mounted) {
      // When solution is toggled on, seed ephemeral moves into PGN once
      // and advance one ply past the current position so the board shows
      // the move the user needed to find.
      if (_session.showSolution && _session.currentPosition != null) {
        _solutionNav.ensureSeeded();
        _solutionNav.navigateToIndex(_session.currentMoveIndex);
      }

      // Auto-blur move input when puzzle is resolved or solution is shown.
      if (_session.positionSolved || _session.showSolution) {
        TacticsControlPanel.moveInputKey.currentState?.unfocus();
        _focusNode.requestFocus();
      }

      // Refocus move input when opponent finishes moving in multi-move puzzles.
      if (_wasWaitingForOpponent &&
          !_session.waitingForOpponent &&
          !_session.positionSolved &&
          !_session.showSolution) {
        TacticsControlPanel.moveInputKey.currentState?.focus();
      }
      _wasWaitingForOpponent = _session.waitingForOpponent;

      setState(() {});
    }
  }

  void _onImportChanged() {
    if (mounted) setState(() {});
  }

  void _applyBoardUpdate(TacticsBoardUpdate update) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    try {
      if (update.applyMoveUci != null) {
        final move = Move.parse(update.applyMoveUci!);
        if (move != null) {
          appState.setCurrentPosition(appState.currentPosition.play(move));
          appState.notifyGameChanged();
        }
      } else if (update.setFen != null) {
        final position = Chess.fromSetup(Setup.parseFen(update.setFen!));
        appState.setCurrentPosition(position);
      }
      if (update.san != null) {
        _pgnViewerController.addEphemeralMove(update.san!);
      }
    } catch (e) {
      debugPrint('[TacticsPanel] Board update failed: $e');
    }
  }

  void _applyPositionSetup(TacticsPositionSetup setup) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    try {
      final position = Chess.fromSetup(Setup.parseFen(setup.fen));
      appState.setCurrentPosition(position);
      appState.setBoardFlipped(setup.flipBoard);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _session.feedback = 'Error loading position: $e';
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _import.removeListener(_onImportChanged);
    _appState?.setMoveAttemptedCallback(null);
    _focusNode.dispose();
    _tabController.dispose();
    _lichessUserController.dispose();
    _lichessCountController.dispose();
    _chessComUserController.dispose();
    _stockfishDepthController.dispose();
    _coresController.dispose();
    _depthErrorTimer?.cancel();
    _coresErrorTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPositions() async {
    await _database.loadPositions();
    if (mounted) {
      setState(() {});
      final appState = context.read<AppState>();
      unawaited(_import.refreshPendingCount(
        lichessUsername: appState.lichessUsername,
        chesscomUsername: appState.chesscomUsername,
      ));
      _maybeAutoFetch();
    }
  }

  /// Static flag to prevent auto-fetch from firing multiple times across
  /// widget recreations (e.g. layout breakpoint switches).
  static bool _autoFetchAttempted = false;

  Future<void> _maybeAutoFetch() async {
    if (_autoFetchAttempted) return;
    _autoFetchAttempted = true;

    final appState = _appState ?? context.read<AppState>();

    // Ensure preferences are loaded before checking auto-fetch setting.
    // loadUsernames() may still be in flight if called from main().
    if (!appState.tacticsAutoFetch) {
      await appState.loadUsernames();
      if (!mounted) return;
      if (!appState.tacticsAutoFetch) return;
    }

    if (_import.isImporting) return;

    final lichessUser = appState.lichessUsername;
    final chesscomUser = appState.chesscomUsername;
    if ((lichessUser == null || lichessUser.isEmpty) &&
        (chesscomUser == null || chesscomUser.isEmpty)) {
      return;
    }

    final depth =
        (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25);
    final cores = (int.tryParse(_coresController.text) ?? 1)
        .clamp(1, TacticsImportService.availableCores);

    // Auto-fetch from Lichess if username is set
    if (lichessUser != null && lichessUser.isNotEmpty) {
      final since = appState.lichessLastFetch;
      try {
        await _import.import(
          source: TacticsImportSource.lichess,
          params: TacticsImportParams(
            username: lichessUser,
            mode: TacticsImportMode.sinceDate,
            since: since ?? DateTime.now().subtract(const Duration(days: 7)),
            depth: depth,
            cores: cores,
          ),
        );
        if (mounted && _import.importStatus != null) {
          appState.setLichessLastFetch(DateTime.now());
        }
      } catch (e) {
        debugPrint('Auto-fetch Lichess failed: $e');
        if (mounted) {
          _import.dismissImportStatus();
        }
      }
    }

    if (!mounted) return;

    // Auto-fetch from Chess.com if username is set
    if (chesscomUser != null && chesscomUser.isNotEmpty) {
      final since = appState.chesscomLastFetch;
      try {
        await _import.import(
          source: TacticsImportSource.chessCom,
          params: TacticsImportParams(
            username: chesscomUser,
            mode: TacticsImportMode.sinceDate,
            since: since ?? DateTime.now().subtract(const Duration(days: 7)),
            depth: depth,
            cores: cores,
          ),
        );
        if (mounted && _import.importStatus != null) {
          appState.setChesscomLastFetch(DateTime.now());
        }
      } catch (e) {
        debugPrint('Auto-fetch Chess.com failed: $e');
        if (mounted) {
          _import.dismissImportStatus();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyE): _ToggleInlineEngineIntent(),
      },
      child: Actions(
        actions: {
          _ToggleInlineEngineIntent: CallbackAction<_ToggleInlineEngineIntent>(
            onInvoke: (_) {
              if (_session.currentPosition == null || isTextInputFocused()) {
                return null;
              }
              InlineEngineBar.toggleEngine();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _focusNode.requestFocus(),
            child: Column(
              children: [
                TabBar(
                  controller: _tabController,
                  tabs: [
                    const Tab(text: 'Tactic'),
                    Tab(
                      text: _session.currentPosition != null ? 'PGN' : 'Browse',
                    ),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildTacticTab(),
                      _session.currentPosition != null
                          ? _buildAnalysisTab()
                          : _buildBrowseTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _session.currentPosition == null) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // Space always toggles solution, even when move input is focused
    // (Space can never be part of a chess move SAN).
    if (key == LogicalKeyboardKey.space) {
      _session.toggleSolution();
      return KeyEventResult.handled;
    }

    if (isTextInputFocused()) {
      return KeyEventResult.ignored;
    }

    // Left/Right arrow — navigate solution on Tactic tab, PGN on Analysis tab
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_tabController.index == 0 && _session.showSolution) {
        if (_solutionNav.arrowForward()) setState(() {});
      } else {
        _pgnViewerController.goForward();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_tabController.index == 0 && _session.showSolution) {
        if (_solutionNav.arrowBack()) setState(() {});
      } else {
        _pgnViewerController.goBack();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyP && hasNoLetterModifiers) {
      _loadCurrentPosition(_session.previousPosition());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyN && hasNoLetterModifiers) {
      _loadCurrentPosition(_session.skipPosition());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyJ && hasNoLetterModifiers) {
      _session.setAutoAdvance(!_session.autoAdvance);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyA && hasNoLetterModifiers) {
      final appState = context.read<AppState>();
      final isAtStartingPosition =
          appState.currentPosition.fen == _session.currentPosition!.fen;
      if (isAtStartingPosition) {
        _onAnalyze();
      } else {
        _resetAnalysis();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.slash && hasNoLetterModifiers) {
      TacticsControlPanel.moveInputKey.currentState?.focus();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab) {
      TacticsControlPanel.moveInputKey.currentState?.focus();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  Widget _buildTacticTab() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final current = _session.currentPosition;
        final isAtStartingPosition = current == null ||
            _session.positionSolved ||
            appState.currentPosition.fen == current.fen;

        final ctx = current != null
            ? _session.parsePositionContext(current.positionContext)
            : (moveNumber: null, isWhiteToPlay: null);
        final solutionStartPly = ctx.moveNumber != null
            ? (ctx.moveNumber! - 1) * 2 + ((ctx.isWhiteToPlay ?? true) ? 0 : 1)
            : 0;
        final solutionSan = _session.showSolution && current != null
            ? _solutionNav.sanMoves.isNotEmpty
                ? _solutionNav.sanMoves
                : _session.engine.solutionLineToSan(current)
            : const <String>[];

        return SingleChildScrollView(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (current != null)
                TacticsTrainingPanel(
                  position: current,
                  engine: _session.engine,
                  currentMoveIndex: _session.currentMoveIndex,
                  positionSolved: _session.positionSolved,
                  isAtStartingPosition: isAtStartingPosition,
                  showSolution: _session.showSolution,
                  feedback: _session.feedback,
                  autoAdvance: _session.autoAdvance,
                  onToggleSolution: () => _session.toggleSolution(),
                  onAnalyze: _onAnalyze,
                  onResetAnalysis: _resetAnalysis,
                  onPreviousPosition: () =>
                      _loadCurrentPosition(_session.previousPosition()),
                  onSkipPosition: () =>
                      _loadCurrentPosition(_session.skipPosition()),
                  onAutoAdvanceChanged: _session.setAutoAdvance,
                  onCopyFen: _copyFen,
                  onSetRating: (rating) {
                    _session.setRating(rating);
                    setState(() {});
                  },
                  solutionSanMoves: solutionSan,
                  solutionStartPly: solutionStartPly,
                  activeSolutionMoveIndex: _solutionNav.activeIndex,
                  onSolutionMoveTapped:
                      solutionSan.isNotEmpty ? _onSolutionLineMoveTapped : null,
                )
              else
                TacticsImportPanel(
                  importStatus: _import.importStatus,
                  isImporting: _import.isImporting,
                  activeImport: _import.activeImport,
                  analyzedGameCount: _database.analyzedGameIds.length,
                  lichessUserController: _lichessUserController,
                  lichessCountController: _lichessCountController,
                  chessComUserController: _chessComUserController,
                  stockfishDepthController: _stockfishDepthController,
                  coresController: _coresController,
                  depthError: _depthError,
                  coresError: _coresError,
                  importFieldsValid: _importFieldsValid,
                  onValidateDepth: _validateDepth,
                  onValidateCores: _validateCores,
                  onImportLichess: _importLichess,
                  onImportChessCom: _importChessCom,
                  onDismissImportStatus: _import.dismissImportStatus,
                  onCancelImport: _import.cancelImport,
                  positions: _database.positions,
                  onStartSession: _onStartSession,
                  clearDatabaseEnabled: !_import.isImporting,
                  onClearDatabase: _confirmClearDatabase,
                  onBrowseTactics: () => _tabController.animateTo(1),
                  fetchMode: _fetchMode,
                  onFetchModeChanged: (mode) {
                    if (mounted) setState(() => _fetchMode = mode);
                  },
                  sinceDate: _sinceDate,
                  onSinceDateChanged: (date) {
                    if (mounted) setState(() => _sinceDate = date);
                  },
                  pendingGameCount: _import.pendingGameCount,
                  totalStoredGames: _import.totalStoredGames,
                  onResumeAnalysis: _resumeAnalysis,
                ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Analysis (PGN) tab
  // ---------------------------------------------------------------------------

  Widget _buildAnalysisTab() {
    if (_session.currentPosition == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('Load a tactics position to analyze'),
        ),
      );
    }

    final ctx = _session.parsePositionContext(
      _session.currentPosition!.positionContext,
    );

    return PgnWithEngine(
      key: ValueKey('analysis_${_session.currentPosition!.gameId}'),
      gameId: _session.currentPosition!.gameId,
      moveNumber: ctx.moveNumber,
      isWhiteToPlay: ctx.isWhiteToPlay,
      showStartEndButtons: false,
      controller: _pgnViewerController,
      onPositionChanged: (position) {
        if (_tabController.index != 1) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _tabController.index != 1) return;
          final appState = context.read<AppState>();
          final pgnFen = normalizeFen(position.fen);
          final boardFen = normalizeFen(appState.currentPosition.fen);
          if (pgnFen == boardFen) return;
          appState.setCurrentPosition(position);
        });
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Browse tab
  // ---------------------------------------------------------------------------

  Widget _buildBrowseTab() {
    return TacticsBrowsePanel(
      positions: _database.positions,
      selectedFen: _session.currentPosition?.fen,
      onSelectTactic: _selectTacticFromBrowse,
      onDeleteTactic: _deleteTactic,
      onEditTactic: _showEditDialog,
      onClearAll: _confirmClearDatabase,
      onSetRating: (index, rating) async {
        final pos = _database.positions[index];
        await _database.setRating(pos.fen, rating);
        if (mounted) setState(() {});
      },
    );
  }

  void _selectTacticFromBrowse(int index) {
    final pos = _database.positions[index];
    try {
      final setup = _session.selectPosition(pos);
      if (setup != null) _applyPositionSetup(setup);
      _syncPgnToCurrentTactic();
      _focusNode.requestFocus();
    } catch (e) {
      debugPrint('Load position failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.loadPositionFailed, isError: true);
      }
    }
  }

  void _deleteTactic(int index) async {
    final pos = _database.positions[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Tactic'),
        content: Text(
          'Delete this tactic?\n\n'
          '${pos.mistakeType} ${pos.gameWhite} vs ${pos.gameBlack}\n'
          '${pos.positionContext}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _database.positions.removeAt(index);
      await _database.savePositions();
      setState(() {});
    }
  }

  void _confirmClearDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Database'),
        content: Text(
          'Delete all ${_database.positions.length} tactics positions, '
          'imported PGNs, and analyzed-games history?\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Wipe everything: positions, analyzed-games list, and stored PGNs
      await _database.clearPositions();
      await _database.clearAnalyzedGames();
      await StorageFactory.instance.saveImportedPgns('');
      _session.endSession();
      _resetBoardToStart();
    }
  }

  Future<void> _showEditDialog(int index) async {
    final updated = await TacticsEditDialog.show(
      context,
      position: _database.positions[index],
      index: index,
    );

    if (updated != null && mounted) {
      _database.positions[index] = updated;
      await _database.savePositions();
      setState(() {});
    }
  }

  /// Reset the board to the standard starting position (used when returning
  /// to the import screen so a stale tactic FEN isn't left on the board).
  void _resetBoardToStart() {
    final appState = context.read<AppState>();
    appState.setCurrentPosition(Chess.initial);
    appState.setBoardFlipped(false);
  }

  /// Re-sync the PGN viewer's highlighted move to the current tactic position.
  void _syncPgnToCurrentTactic() {
    if (_session.currentPosition == null) return;
    final ctx = _session.parsePositionContext(
      _session.currentPosition!.positionContext,
    );
    if (ctx.moveNumber != null) {
      _pgnViewerController.jumpToMove(
        ctx.moveNumber!,
        ctx.isWhiteToPlay ?? true,
      );
    }
  }

  void _resetAnalysis() {
    if (_session.currentPosition == null) return;

    _solutionNav.reset();
    final setup = _session.resetPuzzleState();
    if (setup != null) _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
  }

  /// Applies a field validation result: updates logical validity immediately and
  /// clears the error when valid, then debounces showing the red error text.
  /// Returns the (possibly new) debounce timer to store for the field.
  Timer? _applyFieldValidation({
    required String? error,
    required Timer? currentTimer,
    required void Function(bool valid) setValid,
    required void Function(String? error) setError,
  }) {
    currentTimer?.cancel();
    setState(() {
      setValid(error == null);
      if (error == null) setError(null);
    });
    if (error == null) return null;
    return Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => setError(error));
    });
  }

  void _validateDepth(String value) {
    final v = int.tryParse(value);
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1 || v > 25) {
      error = 'Must be 1–25';
    }
    _depthErrorTimer = _applyFieldValidation(
      error: error,
      currentTimer: _depthErrorTimer,
      setValid: (valid) => _depthValid = valid,
      setError: (e) => _depthError = e,
    );
  }

  void _validateCores(String value) {
    final v = int.tryParse(value);
    final max = TacticsImportService.availableCores;
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1 || v > max) {
      error = 'Must be 1–$max';
    }
    _coresErrorTimer = _applyFieldValidation(
      error: error,
      currentTimer: _coresErrorTimer,
      setValid: (valid) => _coresValid = valid,
      setError: (e) => _coresError = e,
    );
  }

  bool get _importFieldsValid => _depthValid && _coresValid;

  Future<void> _importLichess() =>
      _runImport(TacticsImportSource.lichess, 'Lichess');

  Future<void> _importChessCom() =>
      _runImport(TacticsImportSource.chessCom, 'Chess.com');

  Future<void> _runImport(TacticsImportSource source, String platform) async {
    final username = source == TacticsImportSource.lichess
        ? _lichessUserController.text.trim()
        : _chessComUserController.text.trim();
    final count = int.tryParse(_lichessCountController.text) ?? 20;

    try {
      await _import.import(
        source: source,
        params: TacticsImportParams(
          username: username,
          mode: _fetchMode,
          maxGames: _fetchMode == TacticsImportMode.recent ? count : 200,
          since: _fetchMode == TacticsImportMode.sinceDate ? _sinceDate : null,
          depth:
              (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25),
          cores: (int.tryParse(_coresController.text) ?? 1)
              .clamp(1, TacticsImportService.availableCores),
        ),
      );
      // Only update last-fetch on non-cancelled completion.
      // cancelImport() clears importStatus; success leaves it non-null.
      if (mounted && _import.importStatus != null) {
        final appState = context.read<AppState>();
        final now = DateTime.now();
        if (source == TacticsImportSource.lichess) {
          appState.setLichessLastFetch(now);
        } else {
          appState.setChesscomLastFetch(now);
        }
      }
    } on TacticsImportUsernameRequired {
      _showUsernameRequired(platform);
    } catch (e) {
      debugPrint('$platform import failed: $e');
      if (mounted) {
        _import.dismissImportStatus();
        showAppSnackBar(context, AppMessages.importFailed, isError: true);
      }
    }
  }

  Future<void> _resumeAnalysis() async {
    final appState = context.read<AppState>();
    final depth =
        (int.tryParse(_stockfishDepthController.text) ?? 15).clamp(1, 25);
    final cores = (int.tryParse(_coresController.text) ?? 1)
        .clamp(1, TacticsImportService.availableCores);

    try {
      await _import.resumeAnalysis(
        lichessUsername: appState.lichessUsername,
        chesscomUsername: appState.chesscomUsername,
        depth: depth,
        cores: cores,
      );
    } catch (e) {
      debugPrint('Resume analysis failed: $e');
      if (mounted) {
        _import.dismissImportStatus();
        showAppSnackBar(context, AppMessages.importFailed, isError: true);
      }
    }
  }

  void _onStartSession(TacticsSessionSettings settings) {
    final setup = _session.startSession(settings);
    if (setup == null) return;
    _loadPositionSetup(setup);
  }

  void _loadCurrentPosition(TacticsPositionSetup? setup) {
    if (setup == null) {
      _sessionComplete();
      return;
    }
    _loadPositionSetup(setup);
  }

  void _loadPositionSetup(TacticsPositionSetup setup) {
    _solutionNav.reset();
    _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
    TacticsControlPanel.moveInputKey.currentState?.focus();
  }

  /// Click handler for a move in the solution line: jump there and repaint.
  void _onSolutionLineMoveTapped(List<String> sanMoves, int clickedIndex) {
    _solutionNav.onMoveTapped(sanMoves, clickedIndex);
    setState(() {});
  }

  void _onAnalyze() {
    _tabController.animateTo(1);
    _focusNode.requestFocus();
  }

  Future<void> _copyFen() async {
    if (_session.currentPosition != null) {
      try {
        await Clipboard.setData(
          ClipboardData(text: _session.currentPosition!.fen),
        );
        if (mounted) {
          showAppSnackBar(context, AppMessages.fenCopied);
        }
      } catch (e) {
        debugPrint('Copy FEN failed: $e');
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardWriteFailed,
              isError: true);
        }
      }
    }
  }

  void _onMoveAttempted(String moveUci) {
    if (_session.currentPosition == null) return;

    final appState = context.read<AppState>();

    if (appState.isAnalysisMode ||
        _session.positionSolved ||
        _session.showSolution) {
      _addMoveToAnalysis(moveUci);
      return;
    }

    String? moveSan;
    try {
      final move = Move.parse(moveUci);
      if (move != null) {
        final (_, san) = appState.currentPosition.makeSan(move);
        moveSan = san;
      }
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }

    final prevIndex = _session.currentMoveIndex;
    final update = _session.processMoveAttempt(
      moveUci: moveUci,
      boardFen: appState.currentPosition.fen,
      schedule: (delay, action) => Future.delayed(delay, action),
      isMounted: () => mounted,
    );
    if (update != null) {
      _applyBoardUpdate(update);
      if (moveSan != null && _session.currentMoveIndex > prevIndex) {
        _pgnViewerController.addEphemeralMove(moveSan);
      }
    }
  }

  void _addMoveToAnalysis(String moveUci) {
    final appState = context.read<AppState>();
    final position = appState.currentPosition;

    try {
      final move = Move.parse(moveUci);
      if (move == null) return;

      final (newPos, san) = position.makeSan(move);
      appState.setCurrentPosition(newPos);
      appState.notifyGameChanged();
      _pgnViewerController.addEphemeralMove(san);
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }

  void _sessionComplete() {
    _session.endSession();
    _resetBoardToStart();

    final session = _session.currentSession;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Complete'),
        content: Text('Great work!\n\n'
            'Positions attempted: ${session.positionsAttempted}\n'
            'Correct: ${session.positionsCorrect}\n'
            'Incorrect: ${session.positionsIncorrect}\n'
            'Accuracy: ${(session.accuracy * 100).toStringAsFixed(1)}%'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showUsernameRequired(String platform) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username Required'),
        content: Text('Please set your $platform username in Settings first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
