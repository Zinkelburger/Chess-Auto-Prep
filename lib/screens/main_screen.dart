import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics/tactics_database.dart';
import '../theme/app_colors.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/tactics_control_panel.dart';
import '../widgets/training/move_input_widget.dart';

import '../features/games/controllers/recent_games_controller.dart';
import '../features/games/services/home_review_runner.dart';
import '../features/games/widgets/tactics_games_pane.dart';
import '../services/engine/engine_lifecycle.dart';
import '../widgets/app_breadcrumb_trail.dart';
import 'analysis_screen.dart';
import 'pgn_viewer_screen.dart';
import 'repertoire_screen.dart';
import 'repertoire_training_screen.dart';
import 'study_screen.dart';
import 'tournament_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const List<AppMode> _supportedModes = [
    AppMode.tactics,
    AppMode.positionAnalysis,
    AppMode.repertoire,
    AppMode.repertoireTrainer,
    AppMode.pgnViewer,
    AppMode.study,
    AppMode.tournament,
  ];

  final Map<AppMode, Widget> _modeViews = <AppMode, Widget>{};

  /// Modes whose first build is scheduled for the next frame (see [build]).
  final Set<AppMode> _scheduledModeBuilds = <AppMode>{};

  AppState? _appState;
  AppMode? _lastMode;

  /// True while the window is paused, hidden, or detaching. Mode switches
  /// must not resume Stockfish until the app is in the foreground again.
  bool _appBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = Provider.of<AppState>(context, listen: false);
      _appState = appState;
      _lastMode = appState.currentMode;
      appState.addListener(_onAppStateChanged);
    });
  }

  void _onAppStateChanged() {
    final appState = _appState;
    if (appState == null) return;
    final currentMode = appState.currentMode;
    final previousMode = _lastMode;
    _lastMode = currentMode;
    if (_appBackgrounded) return;
    _syncEngineToMode(previousMode, currentMode);
  }

  /// Suspend/resume, not toggleOff/toggleOn: leaving an engine pane frees
  /// the workers but must not overwrite the user's persisted preference.
  void _syncEngineToMode(AppMode? previous, AppMode current) {
    final wasHeavy = previous?.usesInteractiveEngine ?? false;
    final isHeavy = current.usesInteractiveEngine;
    if (wasHeavy && !isHeavy) {
      unawaited(EngineLifecycle.instance.suspend());
    } else if (!wasHeavy && isHeavy) {
      unawaited(EngineLifecycle.instance.resume());
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Kill engine processes on background/close without persisting "off"
        // — otherwise every clean exit disabled the engine for the next launch.
        // Skip [inactive]: alt-tab and dialogs fire it without meaning the
        // user left the app.
        if (_appBackgrounded) return;
        _appBackgrounded = true;
        unawaited(EngineLifecycle.instance.suspend());
      case AppLifecycleState.resumed:
        if (!_appBackgrounded) return;
        _appBackgrounded = false;
        final mode = _lastMode;
        if (mode != null && mode.usesInteractiveEngine) {
          unawaited(EngineLifecycle.instance.resume());
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // select, not watch: only a mode change should rebuild the stack, not
    // every AppState notification (board moves, analysis flags, …).
    final activeMode = context.select<AppState, AppMode>(
      (state) => state.currentMode,
    );

    // First visit to a mode: constructing the whole screen inside the same
    // frame as the menu tap is what made switching feel frozen. Present a
    // lightweight loading frame immediately and build the real screen on the
    // next frame instead.
    if (_modeViews[activeMode] == null &&
        !_scheduledModeBuilds.contains(activeMode)) {
      _scheduledModeBuilds.add(activeMode);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _scheduledModeBuilds.remove(activeMode);
          _modeViews[activeMode] ??= _createModeView(activeMode);
        });
      });
    }

    return Scaffold(
      body: IndexedStack(
        index: _supportedModes.indexOf(activeMode),
        children: [
          for (final mode in _supportedModes)
            _modeViews[mode] ??
                (mode == activeMode
                    ? const _ModeLoadingView()
                    : const SizedBox.shrink()),
        ],
      ),
    );
  }

  Widget _createModeView(AppMode mode) {
    switch (mode) {
      case AppMode.tactics:
        return const _TacticsModeView();
      case AppMode.positionAnalysis:
        return const AnalysisScreen();
      case AppMode.repertoire:
        return const RepertoireScreen();
      case AppMode.repertoireTrainer:
        return const RepertoireTrainingScreen();
      case AppMode.pgnViewer:
        return const PgnViewerScreen();
      case AppMode.study:
        return const StudyScreen();
      case AppMode.tournament:
        return const TournamentScreen();
    }
  }
}

/// One-frame placeholder shown while a mode's screen is built for the first
/// time (see [_MainScreenState.build]).
class _ModeLoadingView extends StatelessWidget {
  const _ModeLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _TacticsModeView extends StatelessWidget {
  const _TacticsModeView();

  @override
  Widget build(BuildContext context) {
    // The tactics state owners are provided here — above the layout — so
    // they are a single shared source of truth that outlives any
    // compact/wide rebuild of the panel. `_TacticsModeView` is cached in the
    // IndexedStack, so these are created once and live for the app session.
    // RecentGamesController joins them: the games pane is swapped out for
    // the board during a session, and the loaded list must survive that.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TacticsDatabase>(
          create: (_) => TacticsDatabase(),
        ),
        ChangeNotifierProvider<TacticsSessionController>(
          create: (ctx) =>
              TacticsSessionController(database: ctx.read<TacticsDatabase>()),
        ),
        ChangeNotifierProvider<TacticsImportCoordinator>(
          create: (ctx) =>
              TacticsImportCoordinator(database: ctx.read<TacticsDatabase>()),
        ),
        ChangeNotifierProvider<RecentGamesController>(
          create: (ctx) {
            final appState = ctx.read<AppState>();
            return RecentGamesController(
              lichessUsername: () => appState.lichessUsername,
              chesscomUsername: () => appState.chesscomUsername,
            );
          },
        ),
        // The Start-review pipeline. Lives here, not in the pane: a run must
        // survive the pane being swapped out for the board when the user
        // starts a puzzle while the review is still going.
        ChangeNotifierProvider<HomeReviewRunner>(
          create: (ctx) {
            final appState = ctx.read<AppState>();
            return HomeReviewRunner(
              games: ctx.read<RecentGamesController>(),
              importCoordinator: ctx.read<TacticsImportCoordinator>(),
              lichessUsername: () => appState.lichessUsername,
              chesscomUsername: () => appState.chesscomUsername,
            );
          },
        ),
      ],
      child: const _TacticsModeScaffold(),
    );
  }
}

class _TacticsModeScaffold extends StatelessWidget {
  const _TacticsModeScaffold();

  /// Shared key so view-local state (selected tab, PGN cursor, focus) is
  /// reparented — not recreated — when the layout crosses the compact/wide
  /// breakpoint. The training data itself (database/session/import) lives in
  /// the providers above, so it survives regardless of this key; the key just
  /// avoids re-initializing the panel's UI scaffolding on a resize.
  static final GlobalKey _panelKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // No AppState watch here: board-state changes rebuild only
    // [_TacticsBoardPane]; the scaffold, app bar, and control panel would
    // otherwise rebuild on every AppState notification from any mode — even
    // while this screen sits hidden in the IndexedStack. The one select
    // below fires only when a session starts or ends — that's the moment
    // the left pane swaps between the recent-games list and the board.
    final hasPuzzle = context.select<TacticsSessionController, bool>(
      (session) => session.hasActivePosition,
    );
    final Widget leftPane = hasPuzzle
        ? const _TacticsBoardPane()
        : const TacticsGamesPane();
    // Idle, the games list is the star and gets the wider half; during a
    // session the board reclaims the traditional even split.
    final leftFlex = hasPuzzle ? 5 : 6;
    final rightFlex = hasPuzzle ? 5 : 4;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        // The back arrow sits in the title row (not the `leading` slot) so
        // the title doesn't shift right when the arrow appears/disappears.
        title: const AppBarTitleWithTrail(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Tactics'),
              SizedBox(width: 8),
              _TacticsAppBarBackButton(),
            ],
          ),
        ),
        actions: const [AppSettingsButton(), AppModeMenuButton()],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < kCompactBreakpoint;

          return isCompact
              ? Column(
                  children: [
                    Expanded(flex: hasPuzzle ? 4 : 5, child: leftPane),
                    const Divider(height: 1, thickness: 1),
                    Expanded(
                      flex: hasPuzzle ? 6 : 5,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TacticsControlPanel(key: _panelKey),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: leftFlex, child: leftPane),
                    Container(width: 1, color: AppColors.outline),
                    Expanded(
                      flex: rightFlex,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TacticsControlPanel(key: _panelKey),
                      ),
                    ),
                  ],
                );
        },
      ),
    );
  }
}

/// Back arrow in the app bar next to the "Tactics" title: shown only while a
/// puzzle is loaded, it leaves the puzzle (end session / back to browse). The
/// action itself lives in the control panel — a focus-tree sibling — so it is
/// routed through [TacticsSessionController.onBackRequested]. Watching the
/// session here keeps rebuilds scoped to this tiny widget, preserving the
/// scaffold's no-watch design.
class _TacticsAppBarBackButton extends StatelessWidget {
  const _TacticsAppBarBackButton();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TacticsSessionController>();
    if (!session.hasActivePosition) return const SizedBox.shrink();
    return IconButton(
      onPressed: () => session.onBackRequested?.call(),
      icon: const Icon(Icons.arrow_back, size: 18),
      tooltip: session.playSource == TacticsPlaySource.browse
          ? 'Back to browse'
          : 'End session',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }
}

class _TacticsBoardPane extends StatelessWidget {
  const _TacticsBoardPane();

  /// Route a board/input move into the tactics session (puzzle validation or
  /// free-play analysis, decided by the session controller).
  void _attemptMove(BuildContext context, String uci) {
    final appState = context.read<AppState>();
    context.read<TacticsSessionController>().handleMoveAttempted(
      moveUci: uci,
      boardFen: appState.currentPosition.fen,
      inAnalysisMode: appState.isAnalysisMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    // Before a puzzle is loaded the board is decorative: the session ignores
    // every move (see TacticsSessionController.handleMoveAttempted), so both
    // the move field and piece dragging would be input that goes nowhere.
    final hasPuzzle = context.select<TacticsSessionController, bool>(
      (session) => session.hasActivePosition,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  position: appState.currentPosition,
                  flipped: appState.boardFlipped,
                  enableUserMoves: hasPuzzle,
                  onPieceSelected: (square) {},
                  onMove: (move) => _attemptMove(context, move.uci),
                ),
              ),
            ),
          ),
          if (hasPuzzle) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: MoveInputWidget(
                key: TacticsControlPanel.moveInputKey,
                position: appState.currentPosition,
                onMove: (move) => _attemptMove(context, move.uci),
                // Route trainer navigation keys (Space, S/P, arrows, …) back
                // to the control panel so they cycle puzzles / step the
                // solution instead of typing into the field. Returns false for
                // move characters, which then type normally.
                onNavigationKey: (event) =>
                    context
                        .read<TacticsSessionController>()
                        .onTrainerNavigationKey
                        ?.call(event.logicalKey) ??
                    false,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
