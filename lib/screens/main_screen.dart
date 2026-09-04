import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../services/games_library/games_library_service.dart'
    show GamesPlatform;
import '../features/tactics/services/tactics_import_coordinator.dart';
import '../features/tactics/controllers/tactics_session_controller.dart';
import '../features/tactics/services/tactics_database.dart';
import '../theme/app_colors.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_settings_button.dart';
import '../features/tactics/widgets/tactics_control_panel.dart';
import '../widgets/trainer_keyboard_scope.dart';
import '../widgets/training/move_input_widget.dart';

import '../features/games/controllers/recent_games_controller.dart';
import '../features/games/services/home_review_runner.dart';
import '../features/engine_tournament/services/tournament_open_watcher.dart';
import '../features/bughouse/widgets/bughouse_screen.dart';
import '../features/databases/widgets/databases_screen.dart';
import '../features/engine_tournament/widgets/engine_tournament_screen.dart';
import '../features/games/widgets/tactics_games_pane.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/file_open_requests.dart';
import '../services/storage/app_paths.dart';
import '../widgets/app_breadcrumb_trail.dart';
import 'analysis_screen.dart';
import 'pgn_viewer_screen.dart';
import 'repertoire_screen.dart';
import 'repertoire_training_screen.dart';
import 'study_screen.dart';

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
    AppMode.engineTournament,
    AppMode.bughouse,
    AppMode.databases,
  ];

  final Map<AppMode, Widget> _modeViews = <AppMode, Widget>{};

  /// Modes whose first build is scheduled for the next frame (see [build]).
  final Set<AppMode> _scheduledModeBuilds = <AppMode>{};

  AppState? _appState;
  AppMode? _lastMode;

  /// Watches for "open this tournament" requests written by the MCP tools.
  /// Lives here rather than in the tournament screen because the whole point
  /// is to arrive from somewhere else — or from a cold start.
  TournamentOpenWatcher? _tournamentOpenWatcher;

  /// Files the desktop asked us to open — a double-clicked .pgn. Here for the
  /// same reason as the tournament watcher: they come from outside the app,
  /// so the always-mounted host screen is what listens.
  FileOpenRequests? _fileOpenRequests;

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
      unawaited(_startTournamentOpenWatcher(appState));
      _startFileOpenRequests(appState);
    });
  }

  void _startFileOpenRequests(AppState appState) {
    final requests = FileOpenRequests(
      onOpen: (paths) {
        if (!mounted) return;
        // The viewer shows one collection at a time, so a multi-file
        // "Open with" lands on the first; the rest are a click away in the
        // file picker.
        appState.handOff(OpenPgnViewer(pgnPath: paths.first));
      },
    );
    _fileOpenRequests = requests;
    unawaited(requests.start());
  }

  /// Never throws and never blocks the first frame: a widget test with no
  /// path_provider, or a machine with no documents directory, simply gets no
  /// watcher.
  Future<void> _startTournamentOpenWatcher(AppState appState) async {
    try {
      final directory = await AppPaths.engineTournamentsDirectory();
      if (!mounted) return;
      final watcher = TournamentOpenWatcher(
        directory: directory,
        onRequest: (id) {
          if (!mounted) return;
          appState.switchToEngineTournament(tournamentId: id);
        },
      );
      _tournamentOpenWatcher = watcher;
      await watcher.start();
    } catch (_) {
      _tournamentOpenWatcher = null;
    }
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
    unawaited(_tournamentOpenWatcher?.stop());
    _tournamentOpenWatcher = null;
    _fileOpenRequests?.stop();
    _fileOpenRequests = null;
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
        // A request may have been written while the window was away, and the
        // directory watch does not fire for events during that time on every
        // platform.
        unawaited(_tournamentOpenWatcher?.check());
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
      // Ctrl+1…8 (Cmd on macOS) jump between modes in the mode menu's order —
      // the chords the menu advertises beside each entry. Bound here, once,
      // above every screen; the screens' own key handlers see the event first
      // and none of them claims a Ctrl+digit.
      body: CallbackShortcuts(
        bindings: {
          for (final mode in availableModeMenuOrder()) ...{
            SingleActivator(
              _digitKey(mode.shortcutNumber),
              control: true,
            ): () =>
                _switchTo(mode),
            SingleActivator(_digitKey(mode.shortcutNumber), meta: true): () =>
                _switchTo(mode),
          },
        },
        child: IndexedStack(
          index: _supportedModes.indexOf(activeMode),
          children: [
            for (final mode in _supportedModes)
              _modeViews[mode] ??
                  (mode == activeMode
                      ? const _ModeLoadingView()
                      : const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }

  static LogicalKeyboardKey _digitKey(int n) => switch (n) {
    1 => LogicalKeyboardKey.digit1,
    2 => LogicalKeyboardKey.digit2,
    3 => LogicalKeyboardKey.digit3,
    4 => LogicalKeyboardKey.digit4,
    5 => LogicalKeyboardKey.digit5,
    6 => LogicalKeyboardKey.digit6,
    7 => LogicalKeyboardKey.digit7,
    8 => LogicalKeyboardKey.digit8,
    _ => LogicalKeyboardKey.digit9,
  };

  /// Same guard as the menu: no switching while generation holds the app.
  void _switchTo(AppMode mode) {
    final appState = _appState ?? context.read<AppState>();
    if (appState.isRepertoireGenerating) return;
    if (appState.currentMode == mode) return;
    appState.setMode(mode);
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
      case AppMode.engineTournament:
        return const EngineTournamentScreen();
      case AppMode.bughouse:
        return const BughouseScreen();
      case AppMode.databases:
        return const DatabasesScreen();
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
              // The one writer of "last downloaded": the loader that did the
              // downloading tells AppState, and the accounts card reads it
              // back. Both panes then describe the same event.
              onFetched: (platform, at) => platform == GamesPlatform.lichess
                  ? appState.setLichessLastFetch(at)
                  : appState.setChesscomLastFetch(at),
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

  /// The home column's width, the same whether it holds the home blocks or
  /// the puzzle panel: the games list and the board share one left edge, so
  /// nothing jumps when a session starts. (It used to be 40% of the window
  /// idle and 50% in a puzzle.) Below the compact breakpoint the column goes
  /// under the board instead.
  static const double kTacticsColumnWidth = 380;

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

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        // The back arrow sits in the title row (not the `leading` slot) so
        // the breadcrumb trail doesn't shift right when the arrow appears
        // and disappears.
        title: const AppBarTitleWithTrail(title: _TacticsAppBarBackButton()),
        actions: const [AppModeSwitcher(), AppSettingsButton()],
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
                    Expanded(child: leftPane),
                    Container(width: 1, color: AppColors.outline),
                    SizedBox(
                      width: kTacticsColumnWidth,
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
/// routed through [TacticsPanelHooks.back]. Watching the
/// session here keeps rebuilds scoped to this tiny widget, preserving the
/// scaffold's no-watch design.
class _TacticsAppBarBackButton extends StatelessWidget {
  const _TacticsAppBarBackButton();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TacticsSessionController>();
    if (!session.hasActivePosition) return const SizedBox.shrink();
    return IconButton(
      onPressed: () => session.panel?.back?.call(),
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
    return Listener(
      // The board is not focusable, so clicking it leaves the keyboard
      // orphaned on the route scope — out of reach of both the move box and
      // the panel's shortcut handler. The move box keeps its own focus
      // through a board click (MoveInputWidget.onTapOutside); this is the
      // repair for a keyboard that was already orphaned before the click,
      // and it is why the box goes hot again as soon as you touch the board.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => scheduleMicrotask(() {
        if (!keyboardFocusIsOrphaned()) return;
        TacticsControlPanel.moveInputKey.currentState?.focus();
      }),
      child: Container(
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
                          .panel
                          ?.navigationKey
                          ?.call(event.logicalKey) ??
                      false,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
