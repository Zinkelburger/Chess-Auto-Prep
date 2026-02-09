/// Analysis screen – position analysis view.
library;
///
/// Designed to be embedded as the `body` of [MainScreen]'s Scaffold (no
/// Scaffold of its own) so the main app bar with the mode selector stays
/// visible and there is no double-AppBar nesting.
///
/// Layout: toolbar row  ➜  three-panel [PositionAnalysisWidget].

import 'package:flutter/material.dart';

import '../models/analysis_player_info.dart';
import '../models/position_analysis.dart';
import '../models/opening_tree.dart';
import '../services/analysis_games_service.dart';
import '../services/fen_map_builder.dart';
import '../services/opening_tree_builder.dart';
import '../widgets/position_analysis_widget.dart';
import 'player_selection_screen.dart';

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  final AnalysisGamesService _gamesService = AnalysisGamesService();

  AnalysisPlayerInfo? _currentPlayer;
  PositionAnalysis? _positionAnalysis;
  OpeningTree? _openingTree;
  bool _isAnalyzing = false;
  bool _playerIsWhite = true;

  @override
  void initState() {
    super.initState();
    // Always prompt for player selection on first load.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPlayer == null) {
        _showPlayerSelection();
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  /// Secondary toolbar with title, metadata, colour toggle, and player
  /// selection.  Sits below [MainScreen]'s AppBar.
  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          // ── Title + metadata ──
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Position Analysis', style: theme.textTheme.titleMedium),
                if (_currentPlayer != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _metadataSubtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── White / Black toggle (visible once analysis exists) ──
          if (_positionAnalysis != null) ...[
            SegmentedButton<bool>(
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
              selected: {_playerIsWhite},
              onSelectionChanged: (selection) {
                final chosen = selection.first;
                if (chosen != _playerIsWhite) {
                  setState(() => _playerIsWhite = chosen);
                  _analyzeWeakPositions();
                }
              },
            ),
            const SizedBox(width: 8),
          ],

          // ── Player selection ──
          IconButton(
            icon: const Icon(Icons.person_search),
            tooltip: 'Select Player',
            onPressed: _showPlayerSelection,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    // Loading spinner while analysis is running.
    if (_isAnalyzing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Analyzing positions…'),
          ],
        ),
      );
    }

    // No player selected yet.
    if (_currentPlayer == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 24),
            Text(
              'No Player Selected',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _showPlayerSelection,
              icon: const Icon(Icons.person_search),
              label: const Text('Select Player'),
            ),
          ],
        ),
      );
    }

    // Analysis loaded (or awaiting the first analysis trigger).
    return PositionAnalysisWidget(
      analysis: _positionAnalysis,
      openingTree: _openingTree,
      playerIsWhite: _playerIsWhite,
      onAnalyze: _analyzeWeakPositions,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// One-line summary shown below the toolbar title.
  String get _metadataSubtitle {
    final p = _currentPlayer;
    if (p == null) return '';
    return '${p.gameCount} games · ${p.platformDisplayName} (${p.username})';
  }

  /// Push the player-selection screen and handle the returned choice.
  Future<void> _showPlayerSelection() async {
    final result = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(builder: (_) => const PlayerSelectionScreen()),
    );

    if (result != null && mounted) {
      setState(() {
        _currentPlayer = result;
        _positionAnalysis = null;
        _openingTree = null;
        _playerIsWhite = true;
      });
      await _analyzeWeakPositions();
    }
  }

  /// Build (or load cached) position analysis for the current player + colour.
  Future<void> _analyzeWeakPositions() async {
    final player = _currentPlayer;
    if (player == null) {
      _showError('No player selected. Please select a player first.');
      return;
    }

    setState(() => _isAnalyzing = true);

    try {
      // Load the raw PGN from disk.
      final pgns = await _gamesService.loadAnalysisGames(
        player.platform,
        player.username,
      );
      if (pgns == null || pgns.isEmpty) {
        if (mounted) {
          _showError(
            'No games found. Please re-download games for this player.',
          );
          setState(() => _isAnalyzing = false);
        }
        return;
      }

      final pgnList = AnalysisGamesService.splitPgnIntoGames(pgns);
      if (pgnList.isEmpty) {
        if (mounted) {
          _showError('No valid games found in downloaded data.');
          setState(() => _isAnalyzing = false);
        }
        return;
      }

      final userIsWhite = _playerIsWhite;

      // ── Try the cache first ──
      PositionAnalysis? analysis;

      final cachedData = await _gamesService.loadCachedAnalysis(
        player.platform,
        player.username,
        userIsWhite,
      );

      if (cachedData != null) {
        try {
          analysis = PositionAnalysis.fromJson(cachedData);
        } catch (_) {
          // Corrupted cache – fall through to fresh analysis.
        }
      }

      // ── Fresh analysis if cache missed ──
      if (analysis == null) {
        final fenBuilder = FenMapBuilder();
        await fenBuilder.processPgns(pgnList, player.username, userIsWhite);
        analysis = await FenMapBuilder.fromFenMapBuilder(fenBuilder, pgnList);

        // Persist for next time (non-fatal on failure).
        try {
          await _gamesService.saveCachedAnalysis(
            player.platform,
            player.username,
            userIsWhite,
            analysis.toJson(),
          );
        } catch (_) {}
      }

      // Build opening tree (quick, not cached).
      final openingTree = await OpeningTreeBuilder.buildTree(
        pgnList: pgnList,
        username: player.username,
        userIsWhite: userIsWhite,
      );

      if (mounted) {
        setState(() {
          _positionAnalysis = analysis;
          _openingTree = openingTree;
          _isAnalyzing = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Loaded ${analysis.positionStats.length} positions'
              '${cachedData != null ? ' (cached)' : ''}',
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
      builder: (ctx) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
