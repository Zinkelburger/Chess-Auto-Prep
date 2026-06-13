import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/tactics_control_panel.dart';

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
      EngineLifecycle().toggleOff();
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
      EngineLifecycle().toggleOff();
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
                    const Expanded(
                      flex: 6,
                      child: Padding(
                        padding: EdgeInsets.all(8.0),
                        child: TacticsControlPanel(),
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
                    const Expanded(
                      flex: 5,
                      child: Padding(
                        padding: EdgeInsets.all(8.0),
                        child: TacticsControlPanel(),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: ChessBoardWidget(
            position: appState.currentPosition,
            flipped: appState.boardFlipped,
            onPieceSelected: (square) {
              // Handle piece selection
            },
            onMove: (move) {
              // Use UCI from CompletedMove and send to validation
              appState.onMoveAttempted(move.uci);
            },
          ),
        ),
      ),
    );
  }
}
