import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chess/chess.dart' as chess;

import '../core/app_state.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/tactics_control_panel.dart';
import '../services/imported_games_service.dart';
import 'analysis_screen.dart';
import 'repertoire_screen.dart';
import 'repertoire_training_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = Provider.of<AppState>(context, listen: false);
      appState.loadUsernames();
      appState.loadSavedGames();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Chess Auto Prep'),
            actions: [
              // Mode selector
              PopupMenuButton<AppMode>(
                icon: const Icon(Icons.view_module),
                tooltip: 'Select Mode',
                onSelected: (mode) {
                  appState.setMode(mode);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: AppMode.tactics,
                    child: Row(
                      children: [
                        const Icon(Icons.psychology),
                        const SizedBox(width: 12),
                        const Text('Tactics'),
                        if (appState.currentMode == AppMode.tactics)
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.check, size: 16, color: Colors.green),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: AppMode.positionAnalysis,
                    child: Row(
                      children: [
                        const Icon(Icons.analytics),
                        const SizedBox(width: 12),
                        const Text('Player Analysis'),
                        if (appState.currentMode == AppMode.positionAnalysis)
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.check, size: 16, color: Colors.green),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: AppMode.repertoire,
                    child: Row(
                      children: [
                        const Icon(Icons.library_books),
                        const SizedBox(width: 12),
                        const Text('Repertoire Builder'),
                        if (appState.currentMode == AppMode.repertoire)
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.check, size: 16, color: Colors.green),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: AppMode.repertoireTrainer,
                    child: Row(
                      children: [
                        const Icon(Icons.school),
                        const SizedBox(width: 12),
                        const Text('Repertoire Trainer'),
                        if (appState.currentMode == AppMode.repertoireTrainer)
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.check, size: 16, color: Colors.green),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: _buildBodyForMode(appState),
        );
      },
    );
  }

  Widget _buildBodyForMode(AppState appState) {
    switch (appState.currentMode) {
      case AppMode.tactics:
        return _buildTacticsLayout(appState);
      case AppMode.positionAnalysis:
        return const AnalysisScreen();
      case AppMode.repertoire:
        return const RepertoireScreen();
      case AppMode.repertoireTrainer:
        return const RepertoireTrainingScreen();
      default:
        return _buildTacticsLayout(appState);
    }
  }

  Widget _buildTacticsLayout(AppState appState) {
    return Row(
      children: [
        // Left panel - Chess board (60% of width)
        Expanded(
          flex: 6,
          child: Container(
            padding: const EdgeInsets.all(16.0),
            child: ChessBoardWidget(
              game: appState.currentGame,
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
    );
  }

  void _showSettings(BuildContext context) {
    final appState = context.read<AppState>();
    final lichessController = TextEditingController(text: appState.lichessUsername ?? '');
    final chesscomController = TextEditingController(text: appState.chesscomUsername ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: lichessController,
                decoration: const InputDecoration(
                  labelText: 'Lichess Username',
                  hintText: 'Enter your Lichess username',
                  helperText: 'Used for importing games from Lichess',
                ),
                onChanged: (value) {
                  appState.setLichessUsername(value.isEmpty ? null : value);
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: chesscomController,
                decoration: const InputDecoration(
                  labelText: 'Chess.com Username',
                  hintText: 'Enter your Chess.com username',
                  helperText: 'Used for filtering tactics from imported games',
                ),
                onChanged: (value) {
                  appState.setChesscomUsername(value.isEmpty ? null : value);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}