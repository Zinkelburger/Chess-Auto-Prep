import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics_database.dart';
import '../theme/app_colors.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/tactics_control_panel.dart';
import '../widgets/training/move_input_widget.dart';

import '../services/engine/engine_lifecycle.dart';
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
  ];

  final Map<AppMode, Widget> _modeViews = <AppMode, Widget>{};

  /// Modes whose first build is scheduled for the next frame (see [build]).
  final Set<AppMode> _scheduledModeBuilds = <AppMode>{};

  AppState? _appState;
  AppMode? _lastMode;

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

    // Suspend/resume, not toggleOff/toggleOn: leaving the tab frees the
    // engine but must not overwrite the user's persisted engine preference.
    if (previousMode == AppMode.repertoire &&
        currentMode != AppMode.repertoire) {
      EngineLifecycle.instance.suspend();
    } else if (previousMode != AppMode.repertoire &&
        currentMode == AppMode.repertoire) {
      EngineLifecycle.instance.resume();
    }

    _lastMode = currentMode;
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // Kill engine processes on app close without persisting "off" —
      // otherwise every clean exit disabled the engine for the next launch.
      EngineLifecycle.instance.suspend();
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
    // The three tactics state owners are provided here — above the layout —
    // so they are a single shared source of truth that outlives any
    // compact/wide rebuild of the panel. `_TacticsModeView` is cached in the
    // IndexedStack, so these are created once and live for the app session.
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
    // while this screen sits hidden in the IndexedStack.
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('Tactics'),
        actions: const [AppModeMenuButton()],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < kCompactBreakpoint;

          return isCompact
              ? Column(
                  children: [
                    const Expanded(flex: 4, child: _TacticsBoardPane()),
                    const Divider(height: 1, thickness: 1),
                    Expanded(
                      flex: 6,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TacticsControlPanel(key: _panelKey),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Expanded(flex: 5, child: _TacticsBoardPane()),
                    Container(width: 1, color: AppColors.outline),
                    Expanded(
                      flex: 5,
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
                  onPieceSelected: (square) {},
                  onMove: (move) => _attemptMove(context, move.uci),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: MoveInputWidget(
              key: TacticsControlPanel.moveInputKey,
              position: appState.currentPosition,
              onMove: (move) => _attemptMove(context, move.uci),
              // Route trainer navigation keys (Space, S/P, arrows, …) back to
              // the control panel so they cycle puzzles / step the solution
              // instead of typing into the field. Returns false for move
              // characters, which then type normally.
              onNavigationKey: (event) =>
                  context
                      .read<TacticsSessionController>()
                      .onTrainerNavigationKey
                      ?.call(event.logicalKey) ??
                  false,
            ),
          ),
        ],
      ),
    );
  }
}
