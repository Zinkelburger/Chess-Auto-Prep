import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chess/chess.dart' as chess;
import 'dart:io';

import '../core/app_state.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/tactics_control_panel.dart';
import '../services/imported_games_service.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chess Auto Prep'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () => _importGames(context),
            tooltip: 'Import Games',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showSettings(context),
          ),
        ],
      ),
      body: Row(
        children: [
          // Left panel - Chess board (60% of width)
          Expanded(
            flex: 6,
            child: Container(
              padding: const EdgeInsets.all(16.0),
              child: Consumer<AppState>(
                builder: (context, appState, child) {
                  return ChessBoardWidget(
                    game: appState.currentGame,
                    flipped: appState.boardFlipped, // Use the smart board flipping logic
                    onPieceSelected: (square) {
                      // Handle piece selection
                    },
                    onMove: (move) {
                      // Convert move to UCI and send to validation
                      final moveUci = '${move.fromAlgebraic}${move.toAlgebraic}';
                      appState.onMoveAttempted(moveUci);
                    },
                  );
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

  void _importGames(BuildContext context) async {
    final appState = context.read<AppState>();
    final importedGamesService = context.read<ImportedGamesService>();

    if (appState.lichessUsername == null) {
      _showUsernameRequired(context, 'Lichess');
      return;
    }

    // Show dialog to get max games input
    final maxGames = await _showMaxGamesDialog(context);
    if (maxGames == null) return;

    appState.setLoading(true);
    try {
      final pgns = await importedGamesService.importLichessGamesWithEvals(
        appState.lichessUsername!,
        null, // No token needed for this endpoint
        maxGames: maxGames,
        progressCallback: (message) {
          // Show progress in a snackbar or update UI
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
          );
        },
      );

      // Save to persistent storage and timestamped file
      await _savePgnToFile(pgns, appState.lichessUsername!);

      if (context.mounted) {
        _showSuccess(context, 'Successfully imported $maxGames games!');
      }

    } catch (e) {
      if (context.mounted) {
        _showError(context, 'Failed to import games: $e');
      }
    } finally {
      appState.setLoading(false);
    }
  }

  Future<void> _savePgnToFile(String pgns, String username) async {
    if (pgns.isEmpty) return;

    // Save to app documents directory (Flutter idiomatic way)
    final directory = await getApplicationDocumentsDirectory();

    // Save as imported_games.pgn (matching Python expectation)
    final file = File('${directory.path}/imported_games.pgn');
    await file.writeAsString(pgns);

    // Also save a timestamped backup
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupFile = File('${directory.path}/lichess_games_${username}_$timestamp.pgn');
    await backupFile.writeAsString(pgns);
  }

  Future<int?> _showMaxGamesDialog(BuildContext context) async {
    final controller = TextEditingController(text: '100');

    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Games'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('How many games would you like to import?'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Number of games',
                hintText: 'Enter number (e.g., 100)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              Navigator.of(context).pop(value);
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  void _showSuccess(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Success'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showUsernameRequired(BuildContext context, [String? platform]) {
    final String message = platform != null
        ? 'Please set your $platform username in Settings first.'
        : 'Please set your usernames in Settings first.';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username Required'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showError(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}