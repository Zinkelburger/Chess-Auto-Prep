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
import '../services/tactics/tactics_import_form.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics/tactics_solution_pgn.dart';
import '../services/tactics_database.dart';
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import 'engine/inline_engine_bar.dart';
import 'trainer_keyboard_scope.dart';
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
  late TacticsDatabase _database;
  late TacticsSessionController _session;
  late TacticsImportCoordinator _import;

  late TabController _tabController;

  /// Import form state (text fields, validation, fetch mode, prefs).
  late final TacticsImportForm _form;

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
    // The state owners live in providers above the layout (see
    // `_TacticsModeView`) so they are a single shared source of truth that
    // survives layout changes. The panel reads them here; it does NOT own
    // their lifecycle and must not dispose them.
    _database = context.read<TacticsDatabase>();
    _session = context.read<TacticsSessionController>();
    _import = context.read<TacticsImportCoordinator>();
    _solutionNav = TacticsSolutionNavigator(
      pgn: _pgnViewerController,
      currentTactic: () => _session.currentPosition,
      solutionToSan: (tactic) => _session.engine.correctLineToSan(tactic),
      syncPgnToTactic: _syncPgnToCurrentTactic,
      setBoardPosition: (position) =>
          context.read<AppState>().setCurrentPosition(position),
    );
    _session.onBoardUpdate = _applyBoardUpdate;
    _session.onPositionSetup = _loadPositionSetup;
    _session.onAnalysisMove = _addMoveToAnalysis;
    _session.onUserMoveAccepted = _pgnViewerController.goForward;
    _session.addListener(_onSessionChanged);
    _import.addListener(_onImportChanged);
    // Reactive safety net: any database mutation (import streaming, delete,
    // edit, rating) repaints the panel without each call site having to
    // remember to setState.
    _database.addListener(_onDbChanged);
    _tabController = TabController(length: 2, vsync: this);

    _form = TacticsImportForm(defaultCores: EngineSettings.instance.workers);
    _form.addListener(_onFormChanged);

    // Initialize the form from AppState and reset board
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        _form.lichessUser.text = appState.lichessUsername ?? '';
        _form.chessComUser.text = appState.chesscomUsername ?? '';
        _form.loadPrefs();

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
    final pool = StockfishPool.instance;
    final targetWorkers = EngineSettings.instance.workers;
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

  void _onFormChanged() {
    if (mounted) setState(() {});
  }

  void _onDbChanged() {
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
        _pgnViewerController.goForward();
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
    // Detach our listeners/callbacks but do NOT dispose the owners — they are
    // provider-owned (see `_TacticsModeView`) and shared/outlive this panel.
    _session.removeListener(_onSessionChanged);
    _import.removeListener(_onImportChanged);
    _database.removeListener(_onDbChanged);
    _session.onBoardUpdate = null;
    _session.onPositionSetup = null;
    _session.onAnalysisMove = null;
    _session.onUserMoveAccepted = null;
    _focusNode.dispose();
    _tabController.dispose();
    _form.removeListener(_onFormChanged);
    _form.dispose();
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

    final appState = context.read<AppState>();

    // Ensure preferences are loaded before checking auto-fetch setting.
    // loadUsernames() may still be in flight if called from main().
    if (!appState.tacticsAutoFetch) {
      await appState.loadUsernames();
      if (!mounted) return;
      if (!appState.tacticsAutoFetch) return;
    }

    if (_import.isImporting) return;

    await _import.autoFetch(
      lichessUsername: appState.lichessUsername,
      chesscomUsername: appState.chesscomUsername,
      lichessLastFetch: appState.lichessLastFetch,
      chesscomLastFetch: appState.chesscomLastFetch,
      depth: _form.depth,
      cores: _form.cores,
      onFetched: (source, fetchedAt) {
        if (!mounted) return;
        if (source == TacticsImportSource.lichess) {
          appState.setLichessLastFetch(fetchedAt);
        } else {
          appState.setChesscomLastFetch(fetchedAt);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // holdsFocus: the panel keeps keyboard focus for its navigation shortcuts
    // (arrows, p/n/j/a/e) and hands focus to the move input when typing is
    // wanted. Space bubbles to _handleKeyEvent to toggle the solution.
    return TrainerKeyboardScope(
      holdsFocus: true,
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyE): _ToggleInlineEngineIntent(),
      },
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
                : _session.engine.correctLineToSan(current)
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
                  lichessUserController: _form.lichessUser,
                  lichessCountController: _form.fetchCount,
                  chessComUserController: _form.chessComUser,
                  stockfishDepthController: _form.depthText,
                  coresController: _form.coresText,
                  depthError: _form.depthError,
                  coresError: _form.coresError,
                  importFieldsValid: _form.fieldsValid,
                  onValidateDepth: _form.validateDepth,
                  onValidateCores: _form.validateCores,
                  onImportLichess: _importLichess,
                  onImportChessCom: _importChessCom,
                  onDismissImportStatus: _import.dismissImportStatus,
                  onCancelImport: _import.cancelImport,
                  positions: _database.positions,
                  onStartSession: _onStartSession,
                  clearDatabaseEnabled: !_import.isImporting,
                  onClearDatabase: _confirmClearDatabase,
                  onBrowseTactics: () => _tabController.animateTo(1),
                  fetchMode: _form.fetchMode,
                  onFetchModeChanged: _form.setFetchMode,
                  sinceDate: _form.sinceDate,
                  onSinceDateChanged: _form.setSinceDate,
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

    final tactic = _session.currentPosition!;
    final solutionSan = _session.engine.correctLineToSan(tactic);
    final pgnText = buildSolutionPgn(tactic, solutionSan);

    return PgnWithEngine(
      key: ValueKey('analysis_${tactic.fen}'),
      pgnText: pgnText,
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
      onBatchDelete: _batchDeleteTactics,
    );
  }

  Future<void> _batchDeleteTactics(List<int> sortedDescIndices) async {
    final count = sortedDescIndices.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Tactics'),
        content: Text('Delete $count selected tactics?\n\nThis cannot be undone.'),
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
      for (final idx in sortedDescIndices) {
        await _database.deletePositionAt(idx);
      }
    }
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
      // Reactive: deletePositionAt notifies, which repaints via _onDbChanged.
      await _database.deletePositionAt(index);
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
      await _database.updatePositionAt(index, updated);
    }
  }

  /// Reset the board to the standard starting position (used when returning
  /// to the import screen so a stale tactic FEN isn't left on the board).
  void _resetBoardToStart() {
    final appState = context.read<AppState>();
    appState.setCurrentPosition(Chess.initial);
    appState.setBoardFlipped(false);
  }

  /// Re-sync the PGN viewer to the tactic start (solution mainline index 0).
  void _syncPgnToCurrentTactic() {
    _pgnViewerController.clearEphemeralMoves();
    _pgnViewerController.goToMainLineIndex(0);
  }

  void _resetAnalysis() {
    if (_session.currentPosition == null) return;

    _solutionNav.reset();
    final setup = _session.resetPuzzleState();
    if (setup != null) _applyPositionSetup(setup);
    _syncPgnToCurrentTactic();
  }

  Future<void> _importLichess() =>
      _runImport(TacticsImportSource.lichess, 'Lichess');

  Future<void> _importChessCom() =>
      _runImport(TacticsImportSource.chessCom, 'Chess.com');

  Future<void> _runImport(TacticsImportSource source, String platform) async {
    _form.savePrefs();

    try {
      await _import.import(source: source, params: _form.paramsFor(source));
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
    try {
      await _import.resumeAnalysis(
        lichessUsername: appState.lichessUsername,
        chesscomUsername: appState.chesscomUsername,
        depth: _form.depth,
        cores: _form.cores,
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
