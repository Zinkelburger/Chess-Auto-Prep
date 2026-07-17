library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import '../screens/puzzle_creator_screen.dart';
import '../services/tactics_database.dart';
import '../services/storage/storage_factory.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import 'engine/engine_gate.dart';
import 'engine/inline_engine_bar.dart';
import 'trainer_keyboard_scope.dart';
import 'pgn_viewer_widget.dart';
import 'pgn_with_engine.dart';
import 'tactics/tactics_browse_panel.dart';
import 'tactics/tactics_edit_dialog.dart';
import 'tactics/tactics_import_panel.dart';
import 'tactics/tactics_session_recap.dart';
import 'tactics/tactics_solution_navigator.dart';
import 'tactics/tactics_training_panel.dart';
import 'training/move_input_widget.dart';

part 'tactics_control_panel/tactics_control_panel_import.dart';
part 'tactics_control_panel/tactics_control_panel_browse.dart';
part 'tactics_control_panel/tactics_control_panel_keyboard.dart';
part 'tactics_control_panel/tactics_control_panel_playback.dart';

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

/// Shared state (fields) for the tactics control panel. The cohesive method
/// groups live in `part` mixins (import, browse, keyboard, playback) that the
/// concrete [_TacticsControlPanelState] applies; lifecycle, listeners, pending
/// puzzle-seed consumption, and the tab builders stay in the concrete class.
abstract class _TacticsControlPanelStateBase extends State<TacticsControlPanel>
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

  /// Show the end-of-session recap card in the Tactic tab (set when the
  /// session queue is exhausted, cleared when a new session starts).
  bool _showRecap = false;

  // Focus node for keyboard shortcuts during training
  final FocusNode _focusNode = FocusNode();

  /// AppState reference for the pending puzzle-seed listener (kept so
  /// dispose() can unsubscribe without touching context).
  AppState? _appStateRef;

  /// Last window cutoff the pending count was computed against.
  DateTime? _lastPendingCutoff;

  /// Debounce for the pending-count refresh: it prunes and re-reads the whole
  /// stored-PGN archive, so it must not run once per keystroke in the days
  /// field (typing "365" would fire it three times).
  Timer? _pendingCountDebounce;

  /// Cache for the analysis tab's solution PGN — building it replays the
  /// solution line with dartchess, which is wasteful on every panel setState.
  /// Keyed on FEN + solution line so an in-place edit invalidates it.
  String? _solutionPgnKey;
  String? _solutionPgnText;
}

class _TacticsControlPanelState extends _TacticsControlPanelStateBase
    with
        _TacticsImportActions,
        _TacticsPlayback,
        _TacticsBrowseActions,
        _TacticsKeyboardActions {
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
    _session.onSessionCompleted = _onQueueExhausted;
    _session.addListener(_onSessionChanged);
    _import.addListener(_onImportChanged);
    // Reactive safety net: any database mutation (import streaming, delete,
    // edit, rating) repaints the panel without each call site having to
    // remember to setState.
    _database.addListener(_onDbChanged);
    // Two tabs: Tactic, plus a second slot that is Browse while nothing is
    // loaded and PGN analysis while a puzzle is on the board (a PGN tab with
    // no puzzle is useless, and Browse is reachable from the puzzle via the
    // back button / walking off either end of the browse queue).
    _tabController = TabController(length: 2, vsync: this);

    _form = TacticsImportForm(defaultCores: EngineSettings.instance.workers);
    _form.addListener(_onFormChanged);
    // Pending/resume only considers games inside the fetch window — older
    // fetched-but-unanalyzed games are expired, not nagged about forever.
    _import.pendingSinceProvider = () => _form.sinceCutoff;
    _lastPendingCutoff = _form.sinceCutoff;

    // Initialize the form from AppState and reset board
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = context.read<AppState>();
        _form.lichessUser.text = appState.lichessUsername ?? '';
        _form.chessComUser.text = appState.chesscomUsername ?? '';
        _form.loadPrefs();

        _resetBoardToStart();

        // "Make puzzle from this position" hooks in other modes set a seed
        // FEN before switching here; consume it now (panel just created) and
        // on later AppState notifications (panel cached in IndexedStack).
        _appStateRef = appState;
        appState.addListener(_onAppStateForPuzzleSeed);
        _consumePendingPuzzleSeed(appState);
        _consumePendingReviewPath(appState);
      }
    });

    // Listen for tab changes to enter/exit analysis mode. Wait for the tab
    // animation to settle: flipping the mode notifies AppState, which rebuilds
    // the whole tactics screen (board pane, import form, browse list) — doing
    // that on the same frame the animation starts is what made switching tabs
    // visibly janky. Analysis mode only applies to the PGN view; switching to
    // Browse (no puzzle loaded) must not touch AppState at all, or the full
    // screen rebuilds under the freshly-built list.
    _tabController.addListener(() {
      if (!mounted || _tabController.indexIsChanging) return;
      final appState = context.read<AppState>();
      if (_tabController.index != 0 && _session.hasActivePosition) {
        appState.enterAnalysisMode();
        _focusNode.requestFocus();
      } else {
        appState.exitAnalysisMode();
      }
    });

    // Auto-load positions on startup
    _loadPositions();

    // Pre-warm Stockfish pool + Maia so imports start instantly — but at
    // genuine framework idle, not inside the startup frame burst. The 45MB
    // Maia ONNX parse is synchronous FFI; running it during first paint janked
    // startup. Imports still lazily force init if the user is quicker than idle.
    SchedulerBinding.instance.scheduleTask(_warmUpEngines, Priority.idle);
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
    // The fetch window moved (days field edited) — recount pending games
    // against it so the resume banner tracks the visible setting.
    final cutoff = _form.sinceCutoff;
    if (cutoff != _lastPendingCutoff) {
      _lastPendingCutoff = cutoff;
      _pendingCountDebounce?.cancel();
      _pendingCountDebounce = Timer(const Duration(milliseconds: 500), () {
        if (mounted) unawaited(_import.refreshPendingCount());
      });
    }
  }

  void _onDbChanged() {
    if (mounted) setState(() {});
  }

  void _onAppStateForPuzzleSeed() {
    final appState = _appStateRef;
    if (appState != null) {
      _consumePendingPuzzleSeed(appState);
      _consumePendingReviewPath(appState);
    }
  }

  void _consumePendingPuzzleSeed(AppState appState) {
    final seed = appState.pendingPuzzleSeedFen;
    if (seed == null || !mounted) return;
    appState.pendingPuzzleSeedFen = null;
    // Defer navigation out of the notify/build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openPuzzleCreator(seedFen: seed);
    });
  }

  /// "Review as puzzles" hook: open a study (or any PGN file) as an
  /// external set.  Stats save back into the file's headers; content edits
  /// belong in Study mode.
  void _consumePendingReviewPath(AppState appState) {
    final path = appState.pendingReviewPgnPath;
    if (path == null || !mounted) return;
    final gameIndex = appState.pendingReviewGameIndex;
    final includeVariations = appState.pendingReviewIncludeVariations;
    appState.pendingReviewPgnPath = null;
    appState.pendingReviewGameIndex = null;
    appState.pendingReviewIncludeVariations = false;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _session.endSession();
      _showRecap = false;
      final count = await _database.openExternalSet(
        path,
        gameIndex: gameIndex,
        includeVariations: includeVariations,
      );
      if (!mounted) return;
      _resetBoardToStart();
      setState(() {});
      showAppSnackBar(
        context,
        count > 0
            ? 'Reviewing "${_database.activeSetName}" as puzzles '
                  '($count position${count == 1 ? '' : 's'}).'
            : 'No reviewable chapters in "${_database.activeSetName}" — '
                  'chapters need moves to train.',
        isError: count == 0,
      );
    });
  }

  Future<void> _openPuzzleCreator({String? seedFen}) async {
    final saved = await PuzzleCreatorScreen.push(
      context,
      database: _database,
      initialFen: seedFen,
    );
    if (saved != null && mounted) {
      showAppSnackBar(context, 'Puzzle saved.');
    }
  }

  @override
  void dispose() {
    // Detach our listeners/callbacks but do NOT dispose the owners — they are
    // provider-owned (see `_TacticsModeView`) and shared/outlive this panel.
    _appStateRef?.removeListener(_onAppStateForPuzzleSeed);
    _session.removeListener(_onSessionChanged);
    _import.removeListener(_onImportChanged);
    _database.removeListener(_onDbChanged);
    _session.onBoardUpdate = null;
    _session.onPositionSetup = null;
    _session.onAnalysisMove = null;
    _session.onUserMoveAccepted = null;
    _session.onSessionCompleted = null;
    _focusNode.dispose();
    _tabController.dispose();
    _pendingCountDebounce?.cancel();
    _form.removeListener(_onFormChanged);
    _form.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // holdsFocus: the panel keeps keyboard focus for its navigation shortcuts
    // and hands focus to the move input when typing is wanted. Keys that can
    // never appear in a move (Space, ↑/↓, p/s/j) bubble to _handleKeyEvent
    // even while typing; move-alphabet keys (n/a/e, ←/→) work only unfocused.
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
          if (_database.isExternalSet) _buildReviewBanner(),
          TabBar(
            controller: _tabController,
            tabs: [
              const Tab(text: 'Tactic'),
              // Second slot: Browse when nothing is loaded, PGN analysis
              // while a puzzle is on the board — never both.
              Tab(text: _session.hasActivePosition ? 'PGN' : 'Browse'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildTacticTab(),
                if (_session.hasActivePosition)
                  _buildAnalysisTab()
                else
                  _buildBrowseTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── External review banner ─────────────────────────────────────────────

  /// Shown while a study is open as flashcards: names what's being reviewed
  /// and is the way back to the tactics database.
  Widget _buildReviewBanner() {
    final theme = Theme.of(context);
    final count = _database.positions.length;
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Icon(
            Icons.school_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Reviewing "${_database.activeSetName}" — '
              '$count card${count == 1 ? '' : 's'}',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: _exitExternalReview,
            child: const Text('Exit review'),
          ),
        ],
      ),
    );
  }

  Widget _buildTacticTab() {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final current = _session.currentPosition;
        final isAtStartingPosition =
            current == null ||
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
                  onPreviousPosition: _session.hasPrevious
                      ? () => _loadCurrentPosition(_session.previousPosition())
                      : null,
                  onSkipPosition: _session.hasNext
                      ? () => _loadCurrentPosition(_session.skipPosition())
                      : null,
                  isLastSessionPuzzle: _session.isAtLastSessionPuzzle,
                  onAutoAdvanceChanged: _session.setAutoAdvance,
                  onCopyFen: _copyFen,
                  onBackToBrowse:
                      _session.playSource == TacticsPlaySource.browse
                      ? _returnToBrowse
                      : null,
                  // Editing is gated by the controller (locked at the unsolved
                  // head of a session) and off entirely for external sets.
                  onEdit: !_database.isExternalSet && _session.canEditCurrent
                      ? _editCurrentTactic
                      : null,
                  onSetRating: (rating) {
                    _session.setRating(rating);
                    setState(() {});
                  },
                  solutionSanMoves: solutionSan,
                  solutionStartPly: solutionStartPly,
                  activeSolutionMoveIndex: _solutionNav.activeIndex,
                  onSolutionMoveTapped: solutionSan.isNotEmpty
                      ? _onSolutionLineMoveTapped
                      : null,
                )
              else if (_showRecap)
                TacticsSessionRecap(
                  solved: _session.outcomeCount(SessionPuzzleOutcome.correct),
                  failed: _session.outcomeCount(SessionPuzzleOutcome.incorrect),
                  skipped: _session.outcomeCount(
                    SessionPuzzleOutcome.unattempted,
                  ),
                  totalTimeSeconds: _session.currentSession.totalTime,
                  onRetryMistakes: _session.sessionMistakes.isNotEmpty
                      ? _retryMistakes
                      : null,
                  onDone: () => setState(() => _showRecap = false),
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
                  sinceDays: _form.sinceDays,
                  onSinceDaysChanged: _form.setSinceDays,
                  pendingGameCount: _import.pendingGameCount,
                  totalStoredGames: _import.totalStoredGames,
                  onResumeAnalysis: _resumeAnalysis,
                  onFetchNew: _fetchNewGames,
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
    final cacheKey = '${tactic.fen}|${tactic.correctLine.join(' ')}';
    if (_solutionPgnKey != cacheKey) {
      _solutionPgnKey = cacheKey;
      _solutionPgnText = buildSolutionPgn(
        tactic,
        _session.engine.correctLineToSan(tactic),
      );
    }
    final pgnText = _solutionPgnText!;

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
      isLoading: _database.isLoading,
      selectedFen: _session.currentPosition?.fen,
      onSelectTactic: _playTacticFromBrowse,
      onDeleteTactic: _deleteTactic,
      onEditTactic: _showEditDialog,
      onClearAll: _confirmClearDatabase,
      onSetRating: (index, rating) async {
        final pos = _database.positions[index];
        await _database.setRating(pos.fen, rating);
        if (mounted) setState(() {});
      },
      onBatchDelete: _batchDeleteTactics,
      onCreatePuzzle: () => _openPuzzleCreator(),
    );
  }
}
