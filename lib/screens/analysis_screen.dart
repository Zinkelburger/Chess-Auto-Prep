/// Analysis screen - Full-screen position analysis view
/// Shows weak positions from downloaded games with three-panel layout
/// Uses separate storage from tactics games

import 'package:flutter/material.dart';

import '../models/position_analysis.dart';
import '../services/fen_map_builder.dart';
import '../services/analysis_games_service.dart';
import '../widgets/position_analysis_widget.dart';
import 'player_selection_screen.dart';

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  final AnalysisGamesService _gamesService = AnalysisGamesService();

  PositionAnalysis? _positionAnalysis;
  bool _isAnalyzing = false;
  bool? _playerIsWhite; // Current POV - null means not analyzed yet
  Map<String, dynamic>? _currentPlayer; // Currently selected player

  @override
  void initState() {
    super.initState();
    // Always show player selection on first load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPlayer == null) {
        _showPlayerSelection();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Analyzing state
    if (_isAnalyzing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Position Analysis')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Analyzing positions...'),
            ],
          ),
        ),
      );
    }

    // No player selected - should rarely happen as we auto-open player selection
    if (_currentPlayer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Position Analysis')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_search, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 24),
              Text('No Player Selected', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _showPlayerSelection,
                icon: const Icon(Icons.person_search),
                label: const Text('Select Player'),
              ),
            ],
          ),
        ),
      );
    }

    // Has player selected - show analysis UI
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Position Analysis', style: TextStyle(fontSize: 16)),
            _buildMetadataSubtitle(),
          ],
        ),
        actions: [
          // White/Black toggle - only show if analysis exists
          if (_positionAnalysis != null && _playerIsWhite != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('White'),
                    icon: Icon(Icons.circle_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('Black'),
                    icon: Icon(Icons.circle, size: 16),
                  ),
                ],
                selected: {_playerIsWhite!},
                onSelectionChanged: (Set<bool> newSelection) {
                  final newColor = newSelection.first;
                  if (newColor != _playerIsWhite) {
                    setState(() {
                      _playerIsWhite = newColor;
                    });
                    // Re-analyze with new color
                    _analyzeWeakPositions();
                  }
                },
              ),
            ),

          // Select player button
          IconButton(
            icon: const Icon(Icons.person_search),
            tooltip: 'Select Player',
            onPressed: _showPlayerSelection,
          ),
        ],
      ),
      body: PositionAnalysisWidget(
        analysis: _positionAnalysis,
        playerIsWhite: _playerIsWhite,
        onAnalyze: _analyzeWeakPositions,
      ),
    );
  }

  /// Build metadata subtitle for app bar
  Widget _buildMetadataSubtitle() {
    if (_currentPlayer == null) return const SizedBox.shrink();

    final platform = _currentPlayer!['platform'] as String? ?? 'Unknown';
    final username = _currentPlayer!['username'] as String? ?? 'Unknown';
    final gameCount = _currentPlayer!['gameCount'] as int? ?? 0;
    final monthsBack = _currentPlayer!['monthsBack'] as int? ?? 3;

    final platformName = platform == 'chesscom' ? 'Chess.com' : 'Lichess';

    return Text(
      '$gameCount games • $platformName ($username) • $monthsBack month${monthsBack == 1 ? '' : 's'}',
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
    );
  }

  /// Show player selection screen
  Future<void> _showPlayerSelection() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (context) => const PlayerSelectionScreen(),
      ),
    );

    if (result != null && mounted) {
      // Player selected - load their games and auto-analyze White
      setState(() {
        _currentPlayer = result;
        _positionAnalysis = null; // Clear previous analysis
        _playerIsWhite = true; // Default to White
      });

      // Auto-analyze with White
      await _analyzeWeakPositions();
    }
  }

  /// Analyze weak positions from downloaded games
  Future<void> _analyzeWeakPositions() async {
    if (_currentPlayer == null) {
      _showError('No player selected. Please select a player first.');
      return;
    }

    final platform = _currentPlayer!['platform'] as String;
    final username = _currentPlayer!['username'] as String;

    setState(() => _isAnalyzing = true);

    try {
      // Load analysis games for current player (from disk, already downloaded)
      final pgns = await _gamesService.loadAnalysisGames(platform, username);

      if (pgns == null || pgns.isEmpty) {
        if (mounted) {
          _showError('No games found. Please re-download games for this player.');
        }
        setState(() => _isAnalyzing = false);
        return;
      }

      final pgnList = _splitPgnIntoGames(pgns);

      if (pgnList.isEmpty) {
        if (mounted) {
          _showError('No valid games found in downloaded data.');
        }
        setState(() => _isAnalyzing = false);
        return;
      }

      // Use the current color (defaults to White on player selection)
      final userIsWhite = _playerIsWhite ?? true;

      // Try to load from cache first
      final cachedData = await _gamesService.loadCachedAnalysis(
        platform,
        username,
        userIsWhite,
      );

      PositionAnalysis? analysis;
      if (cachedData != null) {
        // Load from cache
        try {
          analysis = PositionAnalysis.fromJson(cachedData);
          if (mounted) {
            setState(() {
              _positionAnalysis = analysis;
              _playerIsWhite = userIsWhite;
              _isAnalyzing = false;
            });

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Loaded ${analysis.positionStats.length} positions from cache',
                ),
              ),
            );
          }
          return;
        } catch (e) {
          // Cache corrupted, continue with fresh analysis
        }
      }

      // No cache or cache failed - perform fresh analysis
      final fenBuilder = FenMapBuilder();
      await fenBuilder.processPgns(
        pgnList,
        username,
        userIsWhite,
      );

      // Create position analysis
      analysis = await FenMapBuilder.fromFenMapBuilder(
        fenBuilder,
        pgnList,
      );

      // Save to cache
      try {
        await _gamesService.saveCachedAnalysis(
          platform,
          username,
          userIsWhite,
          analysis.toJson(),
        );
      } catch (e) {
        // Failed to cache, but continue
      }

      if (mounted) {
        setState(() {
          _positionAnalysis = analysis;
          _playerIsWhite = userIsWhite; // Store player color for board orientation
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
