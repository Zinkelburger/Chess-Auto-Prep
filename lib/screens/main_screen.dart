import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/tactics_control_panel.dart';

import '../services/analysis_service.dart';
import '../services/engine/stockfish_pool.dart';
import 'analysis_screen.dart';
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
  ];

  final Map<AppMode, Widget> _modeViews = <AppMode, Widget>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = Provider.of<AppState>(context, listen: false);
      appState.loadUsernames();
      appState.loadSavedGames();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // App is shutting down — send 'quit' to every Stockfish process
      // so we don't leave orphan OS processes behind.
      AnalysisService().dispose();
      StockfishPool().dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final activeMode = _normalizeMode(appState.currentMode);
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

  AppMode _normalizeMode(AppMode mode) {
    switch (mode) {
      case AppMode.pgnViewer:
        return AppMode.tactics;
      case AppMode.tactics:
      case AppMode.positionAnalysis:
      case AppMode.repertoire:
      case AppMode.repertoireTrainer:
        return mode;
    }
  }

  Widget _createModeView(AppMode mode) {
    switch (mode) {
      case AppMode.tactics:
        return const SafeArea(
          bottom: false,
          child: _TacticsModeView(),
        );
      case AppMode.positionAnalysis:
        return const SafeArea(
          bottom: false,
          child: AnalysisScreen(),
        );
      case AppMode.repertoire:
        return const RepertoireScreen();
      case AppMode.repertoireTrainer:
        return const RepertoireTrainingScreen();
      case AppMode.pgnViewer:
        return const SafeArea(
          bottom: false,
          child: _TacticsModeView(),
        );
    }
  }
}

class _TacticsModeView extends StatelessWidget {
  const _TacticsModeView();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 960;

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  bottom: BorderSide(color: theme.dividerColor),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Tactics', style: theme.textTheme.titleMedium),
                  ),
                  const AppModeMenuButton(),
                ],
              ),
            ),
            Expanded(
              child: isCompact
                  ? Column(
                      children: [
                        Expanded(
                          flex: 5,
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
                          flex: 6,
                          child: _TacticsBoardPane(appState: appState),
                        ),
                        Container(
                          width: 1,
                          color: Colors.grey[300],
                        ),
                        const Expanded(
                          flex: 4,
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: TacticsControlPanel(),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TacticsBoardPane extends StatelessWidget {
  const _TacticsBoardPane({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16.0),
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