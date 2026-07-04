import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../services/tactics/tactics_import_coordinator.dart';
import '../services/tactics/tactics_session_controller.dart';
import '../services/tactics_database.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/tactics_control_panel.dart';
import '../widgets/training/move_input_widget.dart';

import '../services/engine/engine_lifecycle.dart';
import 'analysis_screen.dart';
import 'pgn_viewer_screen.dart';
import 'repertoire_screen.dart';
import 'repertoire_training_screen.dart';

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
  ];

  final Map<AppMode, Widget> _modeViews = <AppMode, Widget>{};
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

    if (previousMode == AppMode.repertoire &&
        currentMode != AppMode.repertoire) {
      EngineLifecycle.instance.toggleOff();
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
      EngineLifecycle.instance.toggleOff();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final activeMode = appState.currentMode;
        _modeViews[activeMode] ??= _createModeView(activeMode);

        return Scaffold(
          body: IndexedStack(
            index: _supportedModes.indexOf(activeMode),
            children: [
              for (final mode in _supportedModes)
                _modeViews[mode] ?? const SizedBox.shrink(),
            ],
          ),
        );
      },
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
    }
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
          create: (ctx) => TacticsSessionController(
            database: ctx.read<TacticsDatabase>(),
          ),
        ),
        ChangeNotifierProvider<TacticsImportCoordinator>(
          create: (ctx) => TacticsImportCoordinator(
            database: ctx.read<TacticsDatabase>(),
          ),
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
    final appState = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('Tactics'),
        actions: const [
          AppModeMenuButton(),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < kCompactBreakpoint;

          return isCompact
              ? Column(
                  children: [
                    Expanded(
                      flex: 4,
                      child: _TacticsBoardPane(appState: appState),
                    ),
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
                    Expanded(
                      flex: 5,
                      child: _TacticsBoardPane(appState: appState),
                    ),
                    Container(
                      width: 1,
                      color: Colors.grey[700],
                    ),
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
  const _TacticsBoardPane({required this.appState});

  final AppState appState;

  /// Route a board/input move into the tactics session (puzzle validation or
  /// free-play analysis, decided by the session controller).
  void _attemptMove(BuildContext context, String uci) {
    context.read<TacticsSessionController>().handleMoveAttempted(
          moveUci: uci,
          boardFen: appState.currentPosition.fen,
          inAnalysisMode: appState.isAnalysisMode,
        );
  }

  @override
  Widget build(BuildContext context) {
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
            ),
          ),
        ],
      ),
    );
  }
}
