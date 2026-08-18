library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartchess/dartchess.dart';

import '../core/app_state.dart';
import '../models/engine_settings.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/maia/maia_factory.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_import_form.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics/tactics_solution_pgn.dart';
import '../services/tactics/tactics_database.dart';
import '../services/storage/storage_factory.dart';
import '../services/stored_game_lookup.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
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
import 'study/add_to_study_flow.dart';
import 'training/move_input_widget.dart';

part 'tactics_control_panel/tactics_control_panel_import.dart';
part 'tactics_control_panel/tactics_control_panel_browse.dart';
part 'tactics_control_panel/tactics_control_panel_keyboard.dart';
part 'tactics_control_panel/tactics_control_panel_playback.dart';

/// Tactics training control panel with import, review, and analysis.
class TacticsControlPanel extends StatefulWidget {
  const TacticsControlPanel({super.key});

  /// Shared key for the tactics move-input widget so the `/` and Tab
  /// shortcuts can focus it from the control panel.
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

  /// Tracks solution visibility so the reveal jump fires on the press that
  /// reveals it, not on every subsequent session notification.
  bool _wasShowingSolution = false;

  /// Show the end-of-session recap card in the Tactic tab (set when the
  /// session queue is exhausted, cleared when a new session starts).
  bool _showRecap = false;

  // Focus node for keyboard shortcuts during training
  final FocusNode _focusNode = FocusNode();

  /// Last window cutoff the pending count was computed against.
  DateTime? _lastPendingCutoff;

  /// Debounce for the pending-count refresh: it prunes and re-reads the whole
  /// stored-PGN archive, so it must not run once per keystroke in the days
  /// field (typing "365" would fire it three times).
  Timer? _pendingCountDebounce;

  /// Deferred engine/Maia warm-up (see initState); cancelled on dispose so a
  /// short-lived panel never leaves the FFI init running behind it.
  Timer? _warmUpTimer;

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
      setBoardPosition: (position) =>
          context.read<AppState>().setCurrentPosition(position),
    );
    _session.onBoardUpdate = _applyBoardUpdate;
    _session.onPositionSetup = _loadPositionSetup;
    _session.onAnalysisMove = _addMoveToAnalysis;
    // Nothing to do on top of [_applyBoardUpdate], which already records the
    // accepted move in the PGN tab. This used to step the PGN cursor forward,
    // on the assumption that the solution was the mainline — see the note
    // there for why that stopped being true.
    _session.onUserMoveAccepted = null;
    _session.onSessionCompleted = _onQueueExhausted;
    _session.onBackRequested = _onBackRequested;
    // The Study-tactics button lives in the left pane, beside Review games;
    // setting a puzzle up is still this panel's job.
    _session.onStartRequested = () => _onStartSession(_session.sessionSettings);
    // Bridge navigation keys pressed while the move-input field owns focus back
    // to the panel shortcuts (the field is a focus-tree sibling — see
    // _handleTrainerNavigationKey).
    _session.onTrainerNavigationKey = _handleTrainerNavigationKey;
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
    // Zero duration: tab clicks land on the next frame instead of sliding in
    // over ~300ms — the panel data is already in memory, so there is nothing
    // to wait for.
    _tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: Duration.zero,
    );

    _form = TacticsImportForm();
    _form.addListener(_onFormChanged);
    // Pending/resume only considers games inside the fetch window — older
    // fetched-but-unanalyzed games are expired, not nagged about forever.
    _import.pendingSinceProvider = () => _form.sinceCutoff;
    _lastPendingCutoff = _form.sinceCutoff;

    // Load the form's shared settings and reset the board
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_form.loadPrefs());
        _resetBoardToStart();
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
    unawaited(_loadPositions());

    // Pre-warm Stockfish pool + Maia so imports start instantly — but off the
    // startup frame burst. The 45MB Maia ONNX parse is synchronous FFI;
    // running it during first paint janked startup. Imports still lazily force
    // init if the user is quicker than this.
    //
    // A plain delay, not scheduleTask(Priority.idle). An idle task is refused
    // while anything animates, and SchedulerBinding then re-posts a
    // *zero-delay* timer to retry. That retry loop cannot terminate under a
    // widget test's fake clock: elapse() keeps draining the zero-delay repost
    // without advancing time, so the animation it waits on never gets the
    // frame that would end it. The result is a test that spins at 100% CPU and
    // allocates until it is OOM-killed. It also means that in the real app the
    // warm-up never ran while any spinner was on screen.
    _warmUpTimer = Timer(const Duration(seconds: 2), _warmUpEngines);
  }

  void _onSessionChanged() {
    if (mounted) {
      // Jump to the move the user needed to find, but only on the press that
      // reveals the solution. Doing it on every notification meant any other
      // session change (a rating, the auto-advance toggle) yanked the cursor
      // back to the start of the line while the user was reading it.
      final showingSolution =
          _session.showSolution && _session.currentPosition != null;
      if (showingSolution && !_wasShowingSolution) {
        _solutionNav.navigateToIndex(_session.currentMoveIndex);
      }
      _wasShowingSolution = showingSolution;

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
    _session.onSessionCompleted = null;
    _session.onBackRequested = null;
    _session.onStartRequested = null;
    _session.onTrainerNavigationKey = null;
    _focusNode.dispose();
    _tabController.dispose();
    _pendingCountDebounce?.cancel();
    _warmUpTimer?.cancel();
    _form.removeListener(_onFormChanged);
    _form.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // holdsFocus: the panel keeps keyboard focus for its navigation shortcuts
    // and hands focus to the move input when typing is wanted. While the move
    // input owns focus, keys that navigate the trainer (Space, S/P, J,
    // arrows) are routed back here through _handleTrainerNavigationKey — the
    // field is a focus-tree sibling, so they can't bubble to _handleKeyEvent.
    return TrainerKeyboardScope(
      holdsFocus: true,
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          if (_database.isExternalSet) _buildReviewBanner(),
          Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: [
                    const Tab(text: 'Tactic'),
                    // Second slot: Browse when nothing is loaded, PGN analysis
                    // while a puzzle is on the board — never both.
                    Tab(text: _session.hasActivePosition ? 'PGN' : 'Browse'),
                  ],
                ),
              ),
              if (_session.hasActivePosition) _buildGameMenu(),
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

  // ── Game menu ──────────────────────────────────────────────────────────

  /// Kebab menu next to the tabs while a puzzle is loaded: actions on the
  /// tactic's source game (add to a study, copy the PGN) plus editing the
  /// tactic itself.
  Widget _buildGameMenu() {
    // Same gate as the pencil in the position info: no structural edits on an
    // external set, and no revealing the answer of the unsolved session head.
    final canEdit = !_database.isExternalSet && _session.canEditCurrent;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: 'Game actions',
      onSelected: (action) {
        switch (action) {
          case 'add_to_study':
            unawaited(_addGameToStudy());
          case 'copy_pgn':
            unawaited(_copyGamePgn());
          case 'edit_tactic':
            _editCurrentTactic();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'add_to_study',
          child: Text('Add game to study…'),
        ),
        const PopupMenuItem(value: 'copy_pgn', child: Text('Copy game PGN')),
        PopupMenuItem(
          value: 'edit_tactic',
          enabled: canEdit,
          child: const Text('Edit tactic…'),
        ),
      ],
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
        // The navigator computes the line lazily and caches it per tactic —
        // rebuilding it here would replay it with dartchess on every setState.
        final solutionSan = _session.showSolution && current != null
            ? _solutionNav.sanMoves
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
                  // Editing is gated by the controller (locked at the unsolved
                  // head of a session) and off entirely for external sets.
                  onEdit: !_database.isExternalSet && _session.canEditCurrent
                      ? _editCurrentTactic
                      : null,
                  onSetRating: (rating) {
                    unawaited(_session.setRating(rating));
                    setState(() {});
                  },
                  solutionSanMoves: solutionSan,
                  solutionStartPly: solutionStartPly,
                  activeSolutionMoveIndex: _solutionNav.activeIndex,
                  onSolutionMoveTapped: solutionSan.isNotEmpty
                      ? _onSolutionLineMoveTapped
                      : null,
                  previewFlipped: appState.boardFlipped,
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
                  form: _form,
                  isImporting: _import.isImporting,
                  positions: _database.positions,
                  clearDatabaseEnabled: !_import.isImporting,
                  onClearDatabase: _confirmClearDatabase,
                  onBrowseTactics: () => _tabController.animateTo(1),
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
      // Prefer the full source game captured at mine time — it's self-contained
      // and survives the source game being pruned from storage. Legacy/custom
      // puzzles with no stored game fall back to the solution-only PGN.
      final sourceGame = buildSourceGamePgn(tactic);
      _solutionPgnText = sourceGame.isNotEmpty
          ? sourceGame
          : buildSolutionPgn(tactic, _session.engine.correctLineToSan(tactic));
    }
    final pgnText = _solutionPgnText!;

    return PgnWithEngine(
      key: ValueKey('analysis_${tactic.gameId}_${tactic.fen}'),
      // With a stored source game the full movetext is already in [pgnText], so
      // land on the tactic's position via [initialFen] and skip the by-id
      // lookup (which fails for pruned games). Only legacy puzzles without a
      // stored game still try the lookup; [initialFen] then no-ops harmlessly
      // since the solution-only PGN already starts at the tactic position.
      gameId: (tactic.sourceMovetext.isEmpty && tactic.gameId.isNotEmpty)
          ? tactic.gameId
          : null,
      pgnText: pgnText,
      initialFen: tactic.fen,
      // Full game now shown — offer jump-to-start / jump-to-end so the whole
      // game is reachable in one click, not just move-by-move stepping.
      showStartEndButtons: true,
      controller: _pgnViewerController,
      previewFlipped: context.read<AppState>().boardFlipped,
      // Clicking an engine-line move plays the line up to it as an analysis
      // variation (same behaviour as the study screen's engine bar).
      onLineMoveTapped: (sanMoves, clickedIndex) {
        for (var i = 0; i <= clickedIndex && i < sanMoves.length; i++) {
          _pgnViewerController.addEphemeralMove(sanMoves[i]);
        }
      },
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
      revision: _database.revision,
      isLoading: _database.isLoading,
      selectedFen: _session.currentPosition?.fen,
      onSelectTactic: _playTacticFromBrowse,
      onDeleteTactic: _deleteTactic,
      onEditTactic: _showEditDialog,
      onDeleteAll: _confirmClearDatabase,
      onTrainMany: _trainTactics,
      onSetRating: (index, rating) async {
        final pos = _database.positions[index];
        await _database.setRating(pos.fen, rating);
        if (mounted) setState(() {});
      },
      onBatchDelete: _batchDeleteTactics,
    );
  }
}
