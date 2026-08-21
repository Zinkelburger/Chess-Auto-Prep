/// Analysis screen – position analysis view.
library;

///
/// Designed to be embedded as the `body` of [MainScreen]'s Scaffold while
/// providing its own compact toolbar so the mode switcher stays available
/// without an extra app-wide app bar.
///
/// Layout: toolbar row  ➜  three-panel [PositionAnalysisWidget].

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/holes/services/hole_hunt_config.dart';
import '../features/holes/services/hole_hunt_persistence.dart';
import '../features/holes/services/hole_hunt_service.dart';
import '../features/holes/widgets/hole_hunt_config_dialog.dart';
import '../features/tricks/services/trick_hunt_config.dart';
import '../features/tricks/services/trick_hunt_persistence.dart';
import '../features/tricks/services/trick_hunt_service.dart';
import '../features/tricks/widgets/trick_hunt_config_dialog.dart';
import '../models/analysis_player_info.dart';
import '../models/engine_weakness_result.dart';
import '../models/position_analysis.dart';
import '../utils/fen_utils.dart';
import '../utils/file_mtime.dart';
import '../models/opening_tree.dart';
import '../services/analysis_games_service.dart';
import '../services/engine/generation_lease.dart';
import '../services/engine_weakness_service.dart';
import '../services/maia/maia_factory.dart';
import '../services/unified_analysis_builder.dart';
import '../theme/app_colors.dart';
import '../widgets/engine/engine_gate.dart';
import '../widgets/engine_weakness_dialog.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/position_analysis_widget.dart';
import 'player_selection_screen.dart';

part 'analysis_screen_engine.dart';
part 'analysis_screen_holes.dart';
part 'analysis_screen_tricks.dart';

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

  /// Bridge to the board handoff actions (study / puzzle / PGN viewer),
  /// surfaced in the toolbar kebab next to the colour toggle.
  final PositionAnalysisActions _boardActions = PositionAnalysisActions();

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

  /// True once this player has engine evals to show. A run in flight counts:
  /// it starts by clearing the previous numbers, and without this the AppBar
  /// button would flip its label back mid-run and resize the bar.
  bool get _hasEvals => _engineEvals.isNotEmpty || _evalRunning;

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

  // ── Trick hunt state ────────────────────────────────────────────────
  //
  // Same shape as the hole hunt: reports and configs per colour, live
  // findings and progress for the run in flight.
  final TrickHuntService _trickService = TrickHuntService();
  final Map<bool, AuditResult?> _tricksResults = {true: null, false: null};
  final Map<bool, TrickHuntConfig?> _tricksConfigs = {true: null, false: null};
  List<AuditFinding> _tricksLive = [];
  TrickHuntProgress? _tricksProgress;
  bool _isTrickHunting = false;
  bool _trickHuntIsWhite = true;
  bool _trickHuntCancelled = false;
  bool _trickProbesSkipped = false;

  // Implemented by the concrete state; called from the extracted mixins.
  Future<void> _analyzeBothColors();
  Future<bool> _redownloadGames(int monthsBack);

  void _showError(String message) {
    unawaited(
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
      ),
    );
  }
}

class _AnalysisScreenState extends _AnalysisScreenStateBase
    with _EngineWeaknessMixin, _HoleHuntMixin, _TrickHuntMixin {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPlayer == null) {
        unawaited(_showPlayerSelection());
      }
    });
  }

  @override
  void dispose() {
    _evalService?.dispose();
    // The pending hunt futures notice the flag and release the engine.
    if (_isHunting) _holeService.cancel();
    if (_isTrickHunting) _trickService.cancel();
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
        title: AppBarTitleWithTrail(title: titleBlock),
        actions: [
          if (_currentPlayer != null) ..._buildColorControls(),
          // The one engine action that stays in the bar. It is rendered at all
          // times and disables in place, so nothing in the AppBar moves when a
          // job starts or stops; the two hunts live in the kebab beside it.
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(_hasEvals ? 'Re-analyze' : 'Analyze with Engine'),
            onPressed: _canStartEngineJob ? _showWeaknessConfig : null,
          ),
          _buildActionsMenu(),
          const AppModeMenuButton(),
        ],
      ),
      body: Column(
        children: [
          ..._buildJobProgressStrip(theme),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  /// Engine actions are disabled (never hidden) while any job runs or before
  /// a tree exists to analyze.
  bool get _canStartEngineJob =>
      _openingTree != null &&
      !_isAnalyzing &&
      !_evalRunning &&
      !_isHunting &&
      !_isTrickHunting;

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

  /// Kebab holding everything that isn't the primary engine run: the two
  /// opponent hunts, the position handoffs, then switching player and opening
  /// app settings — the last two were icon buttons of their own until the bar
  /// grew to six controls. Handoffs save a *line* in a study; puzzle-ness is
  /// a marker the user sets on a move inside the study ("Puzzle starts
  /// here"), not a separate authored artifact.
  Widget _buildActionsMenu() {
    return AppOverflowMenu(
      entries: [
        AppMenuEntry(
          label: 'Find holes…',
          icon: Icons.gps_fixed,
          enabled: _canStartEngineJob,
          onRun: () => unawaited(_showHoleHuntConfig()),
          hint:
              'Attacks this player\'s games from the other side and reports\n'
              'where the lines can be beaten: strong moves the games never\n'
              'answer, moves with a verified refutation, and traps a human is\n'
              'likely to fall into. Not the same as Analyze with Engine, which\n'
              'only scores positions by raw eval — results here are ranked by\n'
              'reach probability × gain, so it stays a short list.',
        ),
        AppMenuEntry(
          label: 'Find tricks…',
          icon: Icons.auto_fix_high,
          enabled: _canStartEngineJob,
          onRun: () => unawaited(_showTrickHuntConfig()),
          hint:
              'Plays the other side of this player\'s games and hunts moves\n'
              'that are close to engine-best but poisonous in practice —\n'
              'including novelties the games never faced. A move is reported\n'
              'when the mistakes it invites outweigh what it concedes, ranked\n'
              'by reach probability × net gain.',
        ),
        AppMenuEntry(
          label: 'Add line to study…',
          icon: Icons.menu_book_outlined,
          enabled: _boardActions.hasPosition,
          dividerAbove: true,
          onRun: () => unawaited(_boardActions.addCurrentLineToStudy()),
          hint:
              'Saves the moves that led to this position as a chapter of a '
              'study,\nwith your comments. Review or train it as-is, or flag '
              'a move in the\nstudy with "Puzzle starts here" to train just '
              'that part of the line.',
        ),
        AppMenuEntry(
          label: 'Open games in PGN viewer',
          icon: Icons.open_in_new,
          enabled: _boardActions.canOpenGames,
          onRun: _boardActions.openGamesInPgnViewer,
        ),
        AppMenuEntry(
          label: 'Select player…',
          icon: Icons.person_search,
          dividerAbove: true,
          onRun: _showPlayerSelection,
        ),
        AppMenuEntry(
          label: 'App settings…',
          icon: Icons.settings,
          onRun: () => openAppSettings(context),
        ),
      ],
    );
  }

  // ── Job progress strip (under the AppBar) ───────────────────────
  //
  // Every long-running job reports progress in this transient banner
  // instead of inside the AppBar, so the toolbar controls never move.

  List<Widget> _buildJobProgressStrip(ThemeData theme) {
    if (_isAnalyzing) {
      // Build detail (phase, game counts) already lives in the subtitle.
      return [
        LinearProgressIndicator(
          minHeight: 2,
          value: _analysisTotal > 0 ? _analysisCurrent / _analysisTotal : null,
        ),
      ];
    }
    if (_evalRunning) {
      final pct = _evalTotal > 0
          ? (_evalCompleted / _evalTotal * 100).toStringAsFixed(0)
          : '0';
      return [
        LinearProgressIndicator(
          minHeight: 2,
          value: _evalTotal > 0 ? _evalCompleted / _evalTotal : null,
        ),
        _buildJobStatusRow(
          theme,
          message:
              'Engine evaluation: $_evalCompleted / $_evalTotal positions '
              '($pct%)',
          cancelTooltip: 'Cancel engine evaluation',
          onCancel: _cancelEvalAnalysis,
        ),
      ];
    }
    if (_isHunting) {
      return [
        LinearProgressIndicator(minHeight: 2, value: _holesProgress?.fraction),
        _buildJobStatusRow(
          theme,
          message: _huntCancelled
              ? 'Cancelling hole hunt…'
              : 'Hole hunt: ${_holesProgress?.message ?? 'starting…'}',
          cancelTooltip: 'Cancel hole hunt',
          onCancel: _huntCancelled ? null : _cancelHoleHunt,
        ),
      ];
    }
    if (_isTrickHunting) {
      return [
        LinearProgressIndicator(minHeight: 2, value: _tricksProgress?.fraction),
        _buildJobStatusRow(
          theme,
          message: _trickHuntCancelled
              ? 'Cancelling trick hunt…'
              : 'Trick hunt: ${_tricksProgress?.message ?? 'starting…'}',
          cancelTooltip: 'Cancel trick hunt',
          onCancel: _trickHuntCancelled ? null : _cancelTrickHunt,
        ),
      ];
    }
    return const [];
  }

  Widget _buildJobStatusRow(
    ThemeData theme, {
    required String message,
    required String cancelTooltip,
    required VoidCallback? onCancel,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: cancelTooltip,
            onPressed: onCancel,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
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
    final trickHuntOnDisplayedColor =
        _isTrickHunting && _trickHuntIsWhite == _playerIsWhite;
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
      onStartHoleHunt: _canStartEngineJob ? _showHoleHuntConfig : null,
      tricksResult: _tricksResults[_playerIsWhite],
      tricksLiveFindings: trickHuntOnDisplayedColor ? _tricksLive : const [],
      isTrickHunting: trickHuntOnDisplayedColor,
      tricksProgress: trickHuntOnDisplayedColor ? _tricksProgress : null,
      tricksProbesSkipped:
          _trickProbesSkipped && _trickHuntIsWhite == _playerIsWhite,
      onTricksResultChanged: _onTricksResultChanged,
      onStartTrickHunt: _canStartEngineJob ? _showTrickHuntConfig : null,
      actions: _boardActions,
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
        '${p.gameCount} games · ${p.platformDisplayName} (${p.displayName})'
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
      if (_isTrickHunting) _cancelTrickHunt();
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
    _tricksResults[true] = null;
    _tricksResults[false] = null;
    _tricksConfigs[true] = null;
    _tricksConfigs[false] = null;
    _tricksLive = [];
    _tricksProgress = null;
    _trickProbesSkipped = false;
  }

  // ── Re-download games ───────────────────────────────────────────

  /// Downloads all games for the given month range and returns `true` on
  /// success.
  @override
  Future<bool> _redownloadGames(int monthsBack) async {
    final player = _currentPlayer;
    if (player == null) return false;
    // PGN-file imports have no source to re-download from.
    if (!player.canRedownload) return false;

    _cancelEvalAnalysis();

    final progress = ValueNotifier<String>('Downloading games…');

    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, message, _) => Column(
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
      ),
    );

    try {
      final pgns = await _gamesService.downloadGamesFor(
        player,
        monthsBack: monthsBack,
        onProgress: (msg) => progress.value = msg,
      );

      if (pgns.isEmpty) {
        if (mounted) {
          Navigator.of(context).pop();
          _showError('No games found for ${player.displayName}.');
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
        accounts: player.accounts,
        group: player.group,
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
      unawaited(_analyzeBothColors());
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
      // and restore any saved hole/trick reports.
      await _loadEngineEvals();
      await _loadHolesReports();
      await _loadTricksReports();
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
