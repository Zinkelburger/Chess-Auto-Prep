import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../core/app_state.dart';
import '../widgets/tactics_widget.dart';
import '../widgets/pgn_viewer_widget.dart';
import '../widgets/position_analysis_widget.dart';
import '../services/tactics_service.dart';
import '../services/pgn_service.dart';
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
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Consumer<AppState>(
            builder: (context, appState, child) {
              return PopupMenuButton<AppMode>(
                onSelected: (mode) => appState.setMode(mode),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: AppMode.tactics,
                    child: Text('Tactics Trainer'),
                  ),
                  const PopupMenuItem(
                    value: AppMode.positionAnalysis,
                    child: Text('Position Analysis'),
                  ),
                  const PopupMenuItem(
                    value: AppMode.pgnViewer,
                    child: Text('PGN Viewer'),
                  ),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_getModeText(appState.currentMode)),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              );
            },
          ),
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
      body: Consumer<AppState>(
        builder: (context, appState, child) {
          switch (appState.currentMode) {
            case AppMode.tactics:
              return const TacticsWidget();
            case AppMode.positionAnalysis:
              return const PositionAnalysisWidget();
            case AppMode.pgnViewer:
              return const PgnViewerWidget();
          }
        },
      ),
      floatingActionButton: Consumer<AppState>(
        builder: (context, appState, child) {
          switch (appState.currentMode) {
            case AppMode.tactics:
              return FloatingActionButton(
                onPressed: () => _loadTactics(context),
                tooltip: 'Load Tactics',
                child: const Icon(Icons.psychology),
              );
            case AppMode.positionAnalysis:
              return FloatingActionButton(
                onPressed: () => _analyzeWeakPositions(context),
                tooltip: 'Analyze Positions',
                child: const Icon(Icons.analytics),
              );
            case AppMode.pgnViewer:
              return FloatingActionButton(
                onPressed: () => _loadPgnFiles(context),
                tooltip: 'Load PGN',
                child: const Icon(Icons.file_open),
              );
          }
        },
      ),
    );
  }

  String _getModeText(AppMode mode) {
    switch (mode) {
      case AppMode.tactics:
        return 'Tactics';
      case AppMode.positionAnalysis:
        return 'Analysis';
      case AppMode.pgnViewer:
        return 'PGN Viewer';
    }
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

  void _loadTactics(BuildContext context) async {
    final appState = context.read<AppState>();
    final tacticsService = context.read<TacticsService>();

    if (appState.chesscomUsername == null) {
      _showUsernameRequired(context, 'Chess.com');
      return;
    }

    appState.setLoading(true);
    try {
      final positions = await tacticsService.generateTacticsFromLichess(
        appState.chesscomUsername!,
      );
      appState.setTacticsPositions(positions);
    } catch (e) {
      _showError(context, 'Failed to load tactics: $e');
    } finally {
      appState.setLoading(false);
    }
  }

  void _analyzeWeakPositions(BuildContext context) async {
    final appState = context.read<AppState>();
    final tacticsService = context.read<TacticsService>();

    if (appState.chesscomUsername == null) {
      _showUsernameRequired(context, 'Chess.com');
      return;
    }

    appState.setLoading(true);
    try {
      final positions = await tacticsService.analyzeWeakPositions(
        appState.chesscomUsername!,
      );
      appState.setTacticsPositions(positions);
      appState.setMode(AppMode.tactics);
    } catch (e) {
      _showError(context, 'Failed to analyze positions: $e');
    } finally {
      appState.setLoading(false);
    }
  }

  void _loadPgnFiles(BuildContext context) async {
    final appState = context.read<AppState>();
    final pgnService = context.read<PgnService>();

    appState.setLoading(true);
    try {
      final games = await pgnService.loadPgnFiles();
      appState.setLoadedGames(games);
    } catch (e) {
      _showError(context, 'Failed to load PGN files: $e');
    } finally {
      appState.setLoading(false);
    }
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

      // Parse and load games into app state
      final pgnService = PgnService();
      final games = pgnService.parsePgnContent(pgns);
      appState.setLoadedGames(games);

      // Save to persistent storage and timestamped file
      await appState.saveGames();
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
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final filename = 'lichess_games_${username}_$timestamp.pgn';
    final file = File('${directory.path}/$filename');

    await file.writeAsString(pgns);
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