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
        return Scaffold(
          body: _buildBodyForMode(appState),
        );
      },
    );
  }

  Widget _buildBodyForMode(AppState appState) {
    switch (appState.currentMode) {
      case AppMode.tactics:
        return SafeArea(
          bottom: false,
          child: _buildTacticsLayout(appState),
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
      default:
        return _buildTacticsLayout(appState);
    }
  }

  Widget _buildTacticsLayout(AppState appState) {
    final theme = Theme.of(context);

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
          child: Row(
            children: [
              // Left panel - Chess board (60% of width)
              Expanded(
                flex: 6,
                child: Container(
                  padding: const EdgeInsets.all(16.0),
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

              // Divider
              Container(
                width: 1,
                color: Colors.grey[300],
              ),

              // Right panel - Tabbed control panel (40% of width)
              Expanded(
                flex: 4,
                child: Container(
                  padding: const EdgeInsets.all(8.0),
                  child: const TacticsControlPanel(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

}