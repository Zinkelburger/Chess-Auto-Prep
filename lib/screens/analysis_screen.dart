/// Analysis screen – position analysis view.
library;

///
/// Designed to be embedded as the `body` of [MainScreen]'s Scaffold while
/// providing its own compact toolbar so the mode switcher stays available
/// without an extra app-wide app bar.
///
/// Layout: toolbar row  ➜  three-panel [PositionAnalysisWidget].

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/holes/services/hole_hunt_config.dart';
import '../features/holes/services/hole_hunt_persistence.dart';
import '../features/holes/services/hole_hunt_service.dart';
import '../features/holes/widgets/hole_hunt_config_dialog.dart';
import '../models/analysis_player_info.dart';
import '../models/engine_weakness_result.dart';
import '../models/position_analysis.dart';
import '../utils/fen_utils.dart';
import '../models/opening_tree.dart';
import '../services/analysis_games_service.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/engine_weakness_service.dart';
import '../services/unified_analysis_builder.dart';
import '../theme/app_colors.dart';
import '../widgets/engine/engine_gate.dart';
import '../widgets/engine_weakness_dialog.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/position_analysis_widget.dart';
import 'player_selection_screen.dart';

part 'analysis_screen_engine.dart';
part 'analysis_screen_holes.dart';

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

/// Shared state fields for [AnalysisScreen] plus the cross-group helpers the
/// engine-weakness and hole-hunt mixins call. The concrete [_AnalysisScreenState]
/// supplies [initState]/[build]/[dispose] and the analysis pipeline.
abstract class _AnalysisScreenStateBase extends State<AnalysisScreen> {
  final AnalysisGamesService _gamesService = AnalysisGamesService();

  AnalysisPlayerInfo? _currentPlayer;

  /// Path to the current player's downloaded games PGN (enables the
  /// "Open Games in PGN Viewer" handoff).
  String? _analysisPgnPath;

  // Displayed colour's analysis/tree, plus both colours kept in memory so a
  // colour switch is an instant swap instead of a rebuild.
  PositionAnalysis? _positionAnalysis;
  OpeningTree? _openingTree;
  PositionAnalysis? _whiteAnalysis;
  PositionAnalysis? _blackAnalysis;
  OpeningTree? _whiteTree;
  OpeningTree? _blackTree;
  bool _isAnalyzing = false;
  bool _playerIsWhite = true;

  // ── Build progress state ──────────────────────────────────────────
  String _analysisPhase = '';
  int _analysisCurrent = 0;
  int _analysisTotal = 0;

  // ── Engine eval state ───────────────────────────────────────────────
  List<EngineWeaknessResult> _engineEvals = [];
  EngineWeaknessService? _evalService;
  bool _evalRunning = false;
  int _evalCompleted = 0;
  int _evalTotal = 0;

  bool get _hasEvals => _engineEvals.isNotEmpty;

  // ── Hole hunt state ─────────────────────────────────────────────────
  //
  // Reports are kept per colour (keyed by "player is white"), mirroring the
  // two game trees, and persisted per player + colour.
  final HoleHuntService _holeService = HoleHuntService();
  final Map<bool, AuditResult?> _holesResults = {true: null, false: null};
  final Map<bool, HoleHuntConfig?> _holesConfigs = {true: null, false: null};
  List<AuditFinding> _holesLive = [];
  HoleHuntProgress? _holesProgress;
  bool _isHunting = false;
  bool _huntIsWhite = true;
  bool _huntCancelled = false;
  bool _trapPassSkipped = false;

  // Implemented by the concrete state; called from the extracted mixins.
  Future<void> _analyzeBothColors();
  Future<bool> _redownloadGames(int monthsBack);

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

class _AnalysisScreenState extends _AnalysisScreenStateBase
    with _EngineWeaknessMixin, _HoleHuntMixin {
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
    // The pending hunt future notices the flag and releases the engine.
    if (_isHunting) _holeService.cancel();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Player Analysis', style: theme.textTheme.titleMedium),
        if (_currentPlayer != null)
          Text(
            _metadataSubtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: titleBlock,
        actions: [
          if (_evalRunning) _buildEvalProgress(theme),
          if (_isHunting) _buildHuntProgress(theme),
          if (_currentPlayer != null) ..._buildColorControls(),
          if (_openingTree != null &&
              !_isAnalyzing &&
              !_evalRunning &&
              !_isHunting) ...[
            TextButton.icon(
              icon: const Icon(Icons.psychology, size: 18),
              label: Text(_hasEvals ? 'Re-analyze' : 'Analyze with Engine'),
              onPressed: _showWeaknessConfig,
            ),
            Tooltip(
              message:
                  'Hunt exploitable holes from the opposite side '
                  '(coverage gaps, refutations, expectimax traps) — '
                  'not just bad raw evals',
              child: TextButton.icon(
                icon: const Icon(Icons.gps_fixed, size: 18),
                label: const Text('Find Holes'),
                onPressed: _showHoleHuntConfig,
              ),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.person_search),
            tooltip: 'Select Player',
            onPressed: _showPlayerSelection,
          ),
          const AppModeMenuButton(),
        ],
      ),
      body: Column(
        children: [
          if (_isAnalyzing)
            LinearProgressIndicator(
              minHeight: 2,
              value: _analysisTotal > 0
                  ? _analysisCurrent / _analysisTotal
                  : null,
            ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  List<Widget> _buildColorControls() {
    return [
      Padding(
        padding: const EdgeInsets.only(right: 8),
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
          selected: {_playerIsWhite},
          onSelectionChanged: (selection) {
            if (selection.isEmpty) return;
            final chosen = selection.first;
            if (chosen != _playerIsWhite) {
              _selectColor(chosen);
            }
          },
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    ];
  }

  Widget _buildHuntProgress(ThemeData theme) {
    final progress = _holesProgress;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: progress?.fraction,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _huntCancelled
              ? 'Cancelling hunt…'
              : 'Holes: ${progress?.message ?? 'starting…'}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          tooltip: 'Cancel',
          onPressed: _huntCancelled ? null : _cancelHoleHunt,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        ),
      ],
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
            const Icon(
              Icons.person_search,
              size: 64,
              color: AppColors.onSurfaceDim,
            ),
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

    final huntOnDisplayedColor = _isHunting && _huntIsWhite == _playerIsWhite;
    return PositionAnalysisWidget(
      analysis: _positionAnalysis,
      openingTree: _openingTree,
      playerIsWhite: _playerIsWhite,
      isLoading: _isAnalyzing,
      onAnalyze: _analyzeBothColors,
      hasEvals: _hasEvals,
      playerName: _currentPlayer?.username,
      analysisPgnPath: _analysisPgnPath,
      holesResult: _holesResults[_playerIsWhite],
      holesLiveFindings: huntOnDisplayedColor ? _holesLive : const [],
      isHoleHunting: huntOnDisplayedColor,
      holesProgress: huntOnDisplayedColor ? _holesProgress : null,
      holesTrapPassSkipped: _trapPassSkipped && _huntIsWhite == _playerIsWhite,
      onHolesResultChanged: _onHolesResultChanged,
      onStartHoleHunt: _isHunting || _isAnalyzing ? null : _showHoleHuntConfig,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────

  String get _metadataSubtitle {
    final p = _currentPlayer;
    if (p == null) return '';
    final dl = p.downloadedAt != null
        ? ' · downloaded ${p.downloadTimeAgo}'
        : '';
    final base =
        '${p.gameCount} games · ${p.platformDisplayName} (${p.username})'
        ' · ${p.rangeDescription}$dl';
    if (!_isAnalyzing) return base;
    if (_analysisTotal > 0) {
      return '$base · $_analysisPhase · $_analysisCurrent / $_analysisTotal games';
    }
    if (_analysisPhase.isNotEmpty) return '$base · $_analysisPhase';
    return '$base · Analyzing…';
  }

  Future<void> _showPlayerSelection() async {
    final result = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(builder: (_) => const PlayerSelectionScreen()),
    );

    if (result != null && mounted) {
      _cancelEvalAnalysis();
      if (_isHunting) _cancelHoleHunt();
      setState(() {
        _currentPlayer = result;
        _resetAnalysisState();
      });
      await _analyzeBothColors();
    }
  }

  /// Clear all per-player analysis state (both colours + evals + holes).
  void _resetAnalysisState() {
    _analysisPgnPath = null;
    _positionAnalysis = null;
    _openingTree = null;
    _whiteAnalysis = null;
    _blackAnalysis = null;
    _whiteTree = null;
    _blackTree = null;
    _playerIsWhite = true;
    _engineEvals = [];
    _holesResults[true] = null;
    _holesResults[false] = null;
    _holesConfigs[true] = null;
    _holesConfigs[false] = null;
    _holesLive = [];
    _holesProgress = null;
    _trapPassSkipped = false;
  }

  // ── Re-download games ───────────────────────────────────────────

  /// Downloads all games for the given month range and returns `true` on
  /// success.
  @override
  Future<bool> _redownloadGames(int monthsBack) async {
    final player = _currentPlayer;
    if (player == null) return false;
    // Imported game-sets have no source to re-download from.
    if (player.isImported) return false;

    _cancelEvalAnalysis();

    final progress = ValueNotifier<String>('Downloading games…');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, message, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final String pgns;

      if (player.platform == 'chesscom') {
        pgns = await _gamesService.downloadChesscomGames(
          player.username,
          maxGames: player.maxGames,
          monthsBack: monthsBack,
          onProgress: (msg) => progress.value = msg,
        );
      } else {
        pgns = await _gamesService.downloadLichessGames(
          player.username,
          maxGames: player.maxGames,
          monthsBack: monthsBack,
          onProgress: (msg) => progress.value = msg,
        );
      }

      if (pgns.isEmpty) {
        if (mounted) {
          Navigator.of(context).pop();
          _showError('No games found for ${player.username}.');
        }
        return false;
      }

      progress.value = 'Saving…';

      final updated = await _gamesService.saveAnalysisGames(
        pgns,
        platform: player.platform,
        username: player.username,
        maxGames: player.maxGames,
        monthsBack: monthsBack,
      );

      if (mounted) Navigator.of(context).pop();

      setState(() {
        _currentPlayer = updated;
        _resetAnalysisState();
      });

      return true;
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showError('Re-download failed: $e');
      }
      return false;
    }
  }

  // ── Analysis ─────────────────────────────────────────────────────

  /// Switch the displayed colour. Both colours are kept in memory after a
  /// build, so this is normally an instant swap; the rebuild fallback only
  /// runs if the last build never completed.
  void _selectColor(bool isWhite) {
    setState(() {
      _playerIsWhite = isWhite;
      _positionAnalysis = isWhite ? _whiteAnalysis : _blackAnalysis;
      _openingTree = isWhite ? _whiteTree : _blackTree;
    });
    if (_positionAnalysis == null && !_isAnalyzing) {
      _analyzeBothColors();
    } else {
      _mergeEvalsIntoAnalysis();
    }
  }

  @override
  Future<void> _analyzeBothColors() async {
    final player = _currentPlayer;
    if (player == null) return;

    setState(() {
      _isAnalyzing = true;
      _analysisPhase = 'Loading games';
      _analysisCurrent = 0;
      _analysisTotal = 0;
    });

    try {
      final pgnPath = await _gamesService.analysisPgnPath(
        player.platform,
        player.username,
      );
      final whiteCachePath = await _gamesService.cachedAnalysisPath(
        player.platform,
        player.username,
        true,
      );
      final blackCachePath = await _gamesService.cachedAnalysisPath(
        player.platform,
        player.username,
        false,
      );

      if (!await File(pgnPath).exists()) {
        if (mounted) {
          _showError(
            'No games found. Please re-download games for this player.',
          );
          setState(() => _isAnalyzing = false);
        }
        return;
      }
      if (!mounted || _currentPlayer != player) return;
      _analysisPgnPath = pgnPath;

      // Fast path: both colours restored from the stat-validated disk cache.
      var bundle = await UnifiedAnalysisBuilder.loadCachedBundle(
        pgnFilePath: pgnPath,
        whiteCachePath: whiteCachePath,
        blackCachePath: blackCachePath,
      );

      // Slow path: one isolate reads the file and builds both colours in a
      // single pass, persisting the cache for next time.
      if (bundle == null) {
        if (mounted) {
          setState(() => _analysisPhase = 'Analyzing games');
        }
        bundle = await UnifiedAnalysisBuilder.buildBothInIsolate(
          pgnFilePath: pgnPath,
          username: player.username,
          onProgress: _onBuildProgress,
          whiteCachePath: whiteCachePath,
          blackCachePath: blackCachePath,
        );
      }

      // Guard: the user may have selected a different player while the
      // (possibly minutes-long) build ran — installing this bundle would
      // show the old player's data under the new player's name.
      if (!mounted || _currentPlayer != player) return;
      final result = bundle;
      setState(() {
        _whiteAnalysis = result.whiteAnalysis;
        _blackAnalysis = result.blackAnalysis;
        _whiteTree = result.whiteTree;
        _blackTree = result.blackTree;
        _positionAnalysis = _playerIsWhite ? _whiteAnalysis : _blackAnalysis;
        _openingTree = _playerIsWhite ? _whiteTree : _blackTree;
        _isAnalyzing = false;
        _analysisPhase = '';
        _analysisCurrent = 0;
        _analysisTotal = 0;
      });

      // Merge previously computed engine evals into the displayed analysis,
      // and restore any saved hole reports.
      await _loadEngineEvals();
      await _loadHolesReports();
    } catch (e) {
      if (mounted) {
        _showError('Failed to analyze positions: $e');
        setState(() {
          _isAnalyzing = false;
          _analysisPhase = '';
        });
      }
    }
  }

  void _onBuildProgress(int current, int total) {
    if (mounted) {
      setState(() {
        _analysisCurrent = current;
        _analysisTotal = total;
      });
    }
  }
}
