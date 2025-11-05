/// Analysis screen - Full-screen position analysis view
/// Shows weak positions from imported games with three-panel layout

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../core/app_state.dart';
import '../models/position_analysis.dart';
import '../services/fen_map_builder.dart';
import '../widgets/position_analysis_widget.dart';

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  PositionAnalysis? _positionAnalysis;
  bool _isAnalyzing = false;

  @override
  Widget build(BuildContext context) {
    if (_isAnalyzing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Analyzing positions...'),
          ],
        ),
      );
    }

    return PositionAnalysisWidget(
      analysis: _positionAnalysis,
      onAnalyze: _analyzeWeakPositions,
    );
  }

  /// Analyze weak positions from imported games
  Future<void> _analyzeWeakPositions() async {
    final appState = context.read<AppState>();

    if (appState.chesscomUsername == null) {
      _showUsernameRequired();
      return;
    }

    setState(() => _isAnalyzing = true);

    try {
      // Load imported games from file
      final directory = await getApplicationDocumentsDirectory();
      final pgnFile = File('${directory.path}/imported_games.pgn');

      if (!await pgnFile.exists()) {
        if (mounted) {
          _showError('No imported games found. Please import games first.');
        }
        return;
      }

      final content = await pgnFile.readAsString();
      final pgnList = _splitPgnIntoGames(content);

      if (pgnList.isEmpty) {
        if (mounted) {
          _showError('No games found in imported_games.pgn');
        }
        return;
      }

      // Show color selection dialog
      final userIsWhite = await _showColorSelectionDialog();
      if (userIsWhite == null) return; // User cancelled

      // Build FEN map
      final fenBuilder = FenMapBuilder();
      await fenBuilder.processPgns(
        pgnList,
        appState.chesscomUsername!,
        userIsWhite,
      );

      // Create position analysis
      final analysis = await FenMapBuilder.fromFenMapBuilder(
        fenBuilder,
        pgnList,
      );

      if (mounted) {
        setState(() {
          _positionAnalysis = analysis;
          _isAnalyzing = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Found ${analysis.positionStats.length} positions to analyze',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() => _isAnalyzing = false);
      }
    }
  }

  Future<bool?> _showColorSelectionDialog() async {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Color'),
        content: const Text('Which color do you want to analyze?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('White'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Black'),
          ),
        ],
      ),
    );
  }

  void _showUsernameRequired() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username Required'),
        content: const Text('Please set your Chess.com username in Settings first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
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

  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.isNotEmpty) {
          games.add(currentGame);
        }
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      }
    }

    if (inGame && currentGame.isNotEmpty) {
      games.add(currentGame);
    }

    return games;
  }
}
