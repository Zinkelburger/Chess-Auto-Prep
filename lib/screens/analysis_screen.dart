/// Analysis screen – position analysis view.
library;

///
/// Designed to be embedded as the `body` of [MainScreen]'s Scaffold (no
/// Scaffold of its own) so the main app bar with the mode selector stays
/// visible and there is no double-AppBar nesting.
///
/// Layout: toolbar row  ➜  three-panel [PositionAnalysisWidget].

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/analysis_player_info.dart';
import '../models/engine_weakness_result.dart';
import '../models/position_analysis.dart';
import '../utils/fen_utils.dart';
import '../models/opening_tree.dart';
import '../services/analysis_games_service.dart';
import '../services/engine_weakness_service.dart';
import '../services/fen_map_builder.dart';
import '../services/opening_tree_builder.dart';
import '../widgets/engine_weakness_dialog.dart';
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
  OpeningTree? _whiteTree;
  OpeningTree? _blackTree;
  bool _isAnalyzing = false;
  bool _playerIsWhite = true;

  // ── Engine eval state ───────────────────────────────────────────────
  List<EngineWeaknessResult> _engineEvals = [];
  EngineWeaknessService? _evalService;
  bool _evalRunning = false;
  int _evalCompleted = 0;
  int _evalTotal = 0;

  bool get _hasEvals => _engineEvals.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPlayer == null) {
        _showPlayerSelection();
      }
    });
  }

  @override
  void dispose() {
    _evalService?.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(context),
        if (_isAnalyzing)
          const LinearProgressIndicator(minHeight: 2)
        else
          const Divider(height: 2, thickness: 2),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

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

          // ── Engine eval progress (shown while running) ──
          if (_evalRunning) ...[
            _buildEvalProgress(theme),
            const SizedBox(width: 12),
          ],

          // ── White / Black toggle ──
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

          // ── Engine weakness analysis button ──
          if (_openingTree != null && !_isAnalyzing && !_evalRunning) ...[
            TextButton.icon(
              icon: const Icon(Icons.psychology, size: 18),
              label: Text(_hasEvals ? 'Re-analyze' : 'Weaknesses'),
              onPressed: _showWeaknessConfig,
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

  Widget _buildEvalProgress(ThemeData theme) {
    final pct = _evalTotal > 0
        ? (_evalCompleted / _evalTotal * 100).toStringAsFixed(0)
        : '0';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: _evalTotal > 0 ? _evalCompleted / _evalTotal : null,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Eval $_evalCompleted/$_evalTotal ($pct%)',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          tooltip: 'Cancel',
          onPressed: _cancelEvalAnalysis,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
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

    return PositionAnalysisWidget(
      analysis: _positionAnalysis,
      openingTree: _openingTree,
      playerIsWhite: _playerIsWhite,
      isLoading: _isAnalyzing,
      onAnalyze: _loadColorAnalysis,
      hasEvals: _hasEvals,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────

  String get _metadataSubtitle {
    final p = _currentPlayer;
    if (p == null) return '';
    final base =
        '${p.gameCount} games · ${p.platformDisplayName} (${p.username})'
        ' · ${p.rangeDescription}';
    return _isAnalyzing ? '$base · Analyzing…' : base;
  }

  Future<void> _showPlayerSelection() async {
    final result = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(builder: (_) => const PlayerSelectionScreen()),
    );

    if (result != null && mounted) {
      _cancelEvalAnalysis();
      setState(() {
        _currentPlayer = result;
        _positionAnalysis = null;
        _openingTree = null;
        _whiteTree = null;
        _blackTree = null;
        _playerIsWhite = true;
        _engineEvals = [];
      });
      await _analyzeBothColors();
    }
  }

  // ── Engine weakness analysis ─────────────────────────────────────

  Future<void> _showWeaknessConfig() async {
    if (_whiteTree == null && _blackTree == null) return;

    final config = await showDialog<EngineWeaknessConfig>(
      context: context,
      builder: (_) => EngineWeaknessConfigDialog(
        whiteTree: _whiteTree,
        blackTree: _blackTree,
      ),
    );

    if (config != null && mounted) {
      _runWeaknessAnalysis(config);
    }
  }

  Future<void> _runWeaknessAnalysis(EngineWeaknessConfig config) async {
    _evalService?.dispose();
    _evalService = EngineWeaknessService();

    setState(() {
      _evalRunning = true;
      _evalCompleted = 0;
      _evalTotal = 0;
    });

    try {
      final results = await _evalService!.analyze(
        whiteTree: _whiteTree,
        blackTree: _blackTree,
        minOccurrences: config.minGames,
        depth: config.depth,
        maxWorkers: config.workers,
        maxLoadPercent: config.maxLoadPercent,
        onProgress: (c, t) {
          if (mounted) setState(() { _evalCompleted = c; _evalTotal = t; });
        },
      );

      if (!mounted) return;

      setState(() {
        _engineEvals = results;
        _evalRunning = false;
      });

      _mergeEvalsIntoAnalysis();
      _saveEngineEvals();
    } catch (e) {
      if (mounted) {
        setState(() => _evalRunning = false);
        _showError('Engine analysis failed: $e');
      }
    } finally {
      _evalService?.dispose();
      _evalService = null;
    }
  }

  void _cancelEvalAnalysis() {
    _evalService?.dispose();
    _evalService = null;
    if (mounted) setState(() => _evalRunning = false);
  }

  /// Merge stored engine eval results into the current [_positionAnalysis].
  void _mergeEvalsIntoAnalysis() {
    final analysis = _positionAnalysis;
    if (analysis == null || _engineEvals.isEmpty) return;

    int matched = 0;
    int created = 0;

    for (final r in _engineEvals) {
      if (r.playerIsWhite != _playerIsWhite) continue;

      final key = normalizeFen(r.fen);
      var stats = analysis.positionStats[key];

      if (stats == null) {
        stats = PositionStats(
          fen: key,
          games: r.gamesPlayed,
          wins: r.wins,
          losses: r.losses,
          draws: r.draws,
        );
        analysis.positionStats[key] = stats;
        created++;
      } else {
        matched++;
      }

      stats.evalCp = r.evalCp;
      stats.evalMate = r.evalMate;
      stats.evalDepth = r.depth;

      if (kDebugMode && (matched + created) <= 5) {
        debugPrint('[EvalMerge] ${r.evalDisplay} '
            '(${r.gamesPlayed}g, ${(r.winRate * 100).toStringAsFixed(0)}%) '
            'FEN=$key');
      }
    }

    if (kDebugMode) {
      final forColor = _playerIsWhite ? 'white' : 'black';
      debugPrint('[EvalMerge] $forColor: $matched matched, '
          '$created created, ${_engineEvals.length} total evals');
    }

    setState(() {});
  }

  Future<void> _saveEngineEvals() async {
    final player = _currentPlayer;
    if (player == null || _engineEvals.isEmpty) return;
    try {
      await _gamesService.saveEngineEvals(
        player.platform,
        player.username,
        _engineEvals.map((e) => e.toJson()).toList(),
      );
    } catch (_) {}
  }

  Future<void> _loadEngineEvals() async {
    final player = _currentPlayer;
    if (player == null) return;
    try {
      final data = await _gamesService.loadEngineEvals(
        player.platform,
        player.username,
      );
      if (data != null && mounted) {
        _engineEvals = data
            .map((e) =>
                EngineWeaknessResult.fromJson(e as Map<String, dynamic>))
            .toList();
        _mergeEvalsIntoAnalysis();
      }
    } catch (_) {}
  }

  // ── Analysis ─────────────────────────────────────────────────────

  Future<void> _analyzeBothColors() async {
    final player = _currentPlayer;
    if (player == null) return;

    setState(() => _isAnalyzing = true);

    try {
      final pgnList = await _loadPgnList(player);
      if (pgnList == null) return;

      // ── White first (display immediately) ──
      final (whiteAnalysis, whiteTree) =
          await _buildAnalysis(player, pgnList, true);

      if (mounted) {
        setState(() {
          _positionAnalysis = whiteAnalysis;
          _openingTree = whiteTree;
          _whiteTree = whiteTree;
          _playerIsWhite = true;
          _isAnalyzing = false;
        });
      }

      // Load saved engine evals and merge.
      await _loadEngineEvals();

      // ── Pre-warm Black cache in background ──
      final (_, blackTree) = await _buildAnalysis(player, pgnList, false);
      if (mounted) {
        setState(() => _blackTree = blackTree);
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() => _isAnalyzing = false);
      }
    }
  }

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
          if (_playerIsWhite) {
            _whiteTree = tree;
          } else {
            _blackTree = tree;
          }
          _isAnalyzing = false;
        });
        _mergeEvalsIntoAnalysis();
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() => _isAnalyzing = false);
      }
    }
  }

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

  Future<(PositionAnalysis, OpeningTree)> _buildAnalysis(
    AnalysisPlayerInfo player,
    List<String> pgnList,
    bool isWhite,
  ) async {
    PositionAnalysis? analysis;

    final cachedData = await _gamesService.loadCachedAnalysis(
      player.platform,
      player.username,
      isWhite,
    );
    if (cachedData != null) {
      try {
        analysis = PositionAnalysis.fromJson(cachedData);
      } catch (_) {}
    }

    if (analysis == null) {
      final fenBuilder = FenMapBuilder();
      await fenBuilder.processPgns(pgnList, player.username, isWhite);
      analysis = await FenMapBuilder.fromFenMapBuilder(fenBuilder, pgnList);

      try {
        await _gamesService.saveCachedAnalysis(
          player.platform,
          player.username,
          isWhite,
          analysis.toJson(),
        );
      } catch (_) {}
    }

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
