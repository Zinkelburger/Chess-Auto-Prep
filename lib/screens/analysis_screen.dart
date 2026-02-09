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
        // Thin progress bar that appears/disappears without layout shift.
        if (_isAnalyzing)
          const LinearProgressIndicator(minHeight: 2)
        else
          const Divider(height: 2, thickness: 2),
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
                Text('Player Analysis', style: theme.textTheme.titleMedium),
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

          // ── White / Black toggle (always visible once a player is selected) ──
          if (_currentPlayer != null) ...[
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
                  _loadColorAnalysis();
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

    // Always show the three-panel layout. The widget handles null analysis
    // gracefully (starting-position board, spinner in left pane, etc.).
    return PositionAnalysisWidget(
      analysis: _positionAnalysis,
      openingTree: _openingTree,
      playerIsWhite: _playerIsWhite,
      isLoading: _isAnalyzing,
      onAnalyze: _loadColorAnalysis,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// One-line summary shown below the toolbar title.
  String get _metadataSubtitle {
    final p = _currentPlayer;
    if (p == null) return '';
    final base =
        '${p.gameCount} games · ${p.platformDisplayName} (${p.username})'
        ' · ${p.rangeDescription}';
    return _isAnalyzing ? '$base · Analyzing…' : base;
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
      await _analyzeBothColors();
    }
  }

  // ── Analysis ─────────────────────────────────────────────────────

  /// Analyse **both** colours on first load so toggling White/Black is instant.
  /// Shows the White results as soon as they're ready, then pre-warms Black
  /// in the background.
  Future<void> _analyzeBothColors() async {
    final player = _currentPlayer;
    if (player == null) return;

    setState(() => _isAnalyzing = true);

    try {
      final pgnList = await _loadPgnList(player);
      if (pgnList == null) return; // error already shown

      // ── White first (display immediately) ──
      final (whiteAnalysis, whiteTree) =
          await _buildAnalysis(player, pgnList, true);

      if (mounted) {
        setState(() {
          _positionAnalysis = whiteAnalysis;
          _openingTree = whiteTree;
          _playerIsWhite = true;
          _isAnalyzing = false;
        });
      }

      // ── Pre-warm Black cache in background ──
      await _buildAnalysis(player, pgnList, false);
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() => _isAnalyzing = false);
      }
    }
  }

  /// Load (or rebuild from cache) the analysis for the currently selected
  /// colour.  Used when toggling the White/Black segmented button.
  Future<void> _loadColorAnalysis() async {
    final player = _currentPlayer;
    if (player == null) return;

    setState(() => _isAnalyzing = true);

    try {
      final pgnList = await _loadPgnList(player);
      if (pgnList == null) return;

      final (analysis, tree) =
          await _buildAnalysis(player, pgnList, _playerIsWhite);

      if (mounted) {
        setState(() {
          _positionAnalysis = analysis;
          _openingTree = tree;
          _isAnalyzing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() => _isAnalyzing = false);
      }
    }
  }

  /// Load the raw PGN from disk and split into individual games.
  /// Shows an error dialog and returns `null` on failure.
  Future<List<String>?> _loadPgnList(AnalysisPlayerInfo player) async {
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
      return null;
    }

    final pgnList = AnalysisGamesService.splitPgnIntoGames(pgns);
    if (pgnList.isEmpty) {
      if (mounted) {
        _showError('No valid games found in downloaded data.');
        setState(() => _isAnalyzing = false);
      }
      return null;
    }

    return pgnList;
  }

  /// Build (or load from cache) the position analysis and opening tree
  /// for a single colour.  Caches the result on disk for next time.
  Future<(PositionAnalysis, OpeningTree)> _buildAnalysis(
    AnalysisPlayerInfo player,
    List<String> pgnList,
    bool isWhite,
  ) async {
    // ── Try cache ──
    PositionAnalysis? analysis;

    final cachedData = await _gamesService.loadCachedAnalysis(
      player.platform,
      player.username,
      isWhite,
    );
    if (cachedData != null) {
      try {
        analysis = PositionAnalysis.fromJson(cachedData);
      } catch (_) {
        // Corrupted – fall through to fresh analysis.
      }
    }

    // ── Fresh analysis if cache missed ──
    if (analysis == null) {
      final fenBuilder = FenMapBuilder();
      await fenBuilder.processPgns(pgnList, player.username, isWhite);
      analysis = await FenMapBuilder.fromFenMapBuilder(fenBuilder, pgnList);

      // Persist (non-fatal on failure).
      try {
        await _gamesService.saveCachedAnalysis(
          player.platform,
          player.username,
          isWhite,
          analysis.toJson(),
        );
      } catch (_) {}
    }

    // Opening tree (fast, not cached).
    final tree = await OpeningTreeBuilder.buildTree(
      pgnList: pgnList,
      username: player.username,
      userIsWhite: isWhite,
    );

    return (analysis, tree);
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
