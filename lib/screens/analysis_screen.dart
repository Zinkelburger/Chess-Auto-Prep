/// Analysis screen – position analysis view.
library;

///
/// Designed to be embedded as the `body` of [MainScreen]'s Scaffold while
/// providing its own compact toolbar so the mode switcher stays available
/// without an extra app-wide app bar.
///
/// Layout: toolbar row  ➜  three-panel [PositionAnalysisWidget].

import 'dart:async';
import '../utils/isolate_task.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/holes/services/hole_hunt_config.dart';
import '../features/opponents/models/person_record.dart';
import '../features/opponents/widgets/opponent_actions.dart';
import '../features/opponents/services/opponent_store.dart';
import '../features/opponents/services/prep_context.dart';
import '../features/opponents/services/repertoire_check.dart';
import '../features/opponents/widgets/repertoire_check_dialog.dart';
import '../features/opponents/widgets/tournament_screen.dart';
import '../features/holes/services/hole_hunt_persistence.dart';
import '../features/holes/services/hole_hunt_service.dart';
import '../features/holes/widgets/hole_hunt_config_dialog.dart';
import '../models/analysis_player_info.dart';
import '../models/engine_weakness_result.dart';
import '../models/position_analysis.dart';
import '../utils/fen_utils.dart';
import '../models/opening_tree.dart';
import '../services/analysis_games_service.dart';
import '../services/engine/generation_lease.dart';
import '../services/engine_weakness_service.dart';
import '../services/unified_analysis_builder.dart';
import '../theme/app_colors.dart';
import '../widgets/analysis/player_downloads.dart';
import '../widgets/analysis_download_dialog.dart';
import '../widgets/engine/engine_gate.dart';
import '../widgets/engine_weakness_dialog.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/position_analysis_widget.dart';
import 'player_selection_screen.dart';

part 'analysis_screen_engine.dart';
part 'analysis_screen_holes.dart';
part 'analysis_screen_prep.dart';

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

  // ── Opponent prep (directory + tournament context) ────────────────
  final OpponentStore _opponents = OpponentStore.instance;
  late final OpponentActions _opponentActions = OpponentActions(
    store: _opponents,
    games: _gamesService,
  );
  PrepContext? _prep;

  /// Board position requested from a dialog (the repertoire check); the
  /// generation makes the same FEN requestable twice.
  String? _navigateFen;
  int _navigateGeneration = 0;

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
  String? _analysisFingerprint;
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
  bool _probesSkipped = false;

  // Implemented by the concrete state; called from the extracted mixins.
  Future<void> _selectPlayer(AnalysisPlayerInfo player);

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
    with _EngineWeaknessMixin, _HoleHuntMixin, _PrepMixin {
  @override
  void initState() {
    super.initState();
    unawaited(_opponents.ensureLoaded());
    _opponents.addListener(_onOpponentsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _currentPlayer == null &&
          context.read<AppState>().settingsMode != AppMode.positionAnalysis) {
        unawaited(_showPlayerSelection());
      }
    });
  }

  IsolateTask? _analysisTask;

  @override
  void dispose() {
    _opponents.removeListener(_onOpponentsChanged);
    _analysisTask?.cancel();
    _evalService?.dispose();
    // The pending hunt futures notice the flag and release the engine.
    if (_isHunting) _holeService.cancel();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = _currentPlayer;
    final titleBlock = player == null
        ? const SizedBox.shrink()
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _metadataSubtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Sits beside "downloaded 30d ago" because that is the fact it
              // changes. A PGN-file import has nowhere to fetch from.
              if (player.canRedownload)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Download the latest games…',
                  visualDensity: VisualDensity.compact,
                  onPressed: _isAnalyzing ? null : _showRedownload,
                ),
            ],
          );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: AppBarTitleWithTrail(
          title: Row(
            children: [
              Expanded(child: titleBlock),
              if (player != null) ..._buildColorControls(),
            ],
          ),
        ),
        actions: [
          _buildActionsMenu(),
          const AppModeSwitcher(),
          const AppSettingsButton(mode: AppMode.positionAnalysis),
        ],
      ),
      body: Column(
        children: [
          _buildPrepToolbar(),
          ..._buildJobProgressStrip(theme),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  /// Engine actions are disabled (never hidden) while any job runs or before
  /// a tree exists to analyze.
  bool get _canStartEngineJob =>
      _openingTree != null && !_isAnalyzing && !_evalRunning && !_isHunting;

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

  /// Grouped Actions menu for engine runs, position handoffs and players. The plain engine pass also has a
  /// button where its results show up: the positions list, sorted by eval.
  /// Handoffs save a *line* in a study; puzzle-ness is a marker the user sets
  /// on a move inside the study ("Puzzle starts here"), not a separate
  /// authored artifact.
  Widget _buildActionsMenu() {
    return AppOverflowMenu(
      entries: [
        AppMenuEntry(
          heading: 'Analyze',
          label: _hasEvals ? 'Re-analyze with engine…' : 'Analyze with engine…',
          icon: Icons.memory,
          enabled: _canStartEngineJob,
          onRun: () => unawaited(_showWeaknessConfig()),
          hint:
              'Scores this player\'s most-played positions with Stockfish.\n'
              'Sort the positions list by Bad Eval or Good Eval to see them.',
        ),
        AppMenuEntry(
          label: 'Find holes…',
          icon: Icons.gps_fixed,
          enabled: _canStartEngineJob,
          onRun: () => unawaited(_showHoleHuntConfig()),
          hint:
              'Attacks this player\'s games from the other side and reports\n'
              'where the lines can be beaten: strong moves the games never\n'
              'answer, moves with a verified refutation, and tricks — near-\n'
              'best moves and novelties that score better in practice than\n'
              'the engine move. Not the same as Analyze with Engine, which\n'
              'only scores positions by raw eval — results here are ranked by\n'
              'reach probability × gain, so it stays a short list.',
        ),
        AppMenuEntry(
          label: 'Check against my repertoire…',
          icon: Icons.menu_book_outlined,
          enabled: _openingTree != null && !_isAnalyzing,
          onRun: () => unawaited(_runRepertoireCheck()),
          hint:
              'Walks this player\'s games on the displayed colour through the\n'
              'book you designated for the other colour (My books on the\n'
              'Tactics page) and lists the moves it has no answer to.',
        ),
        AppMenuEntry(
          heading: 'Study and games',
          label: 'Add line to study…',
          icon: Icons.library_add_outlined,
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
          heading: 'Player',
          label: 'Choose a player…',
          icon: Icons.person_search,
          dividerAbove: true,
          onRun: _showPlayerSelection,
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
              'No player selected',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick whose games to analyze — yours or an opponent’s.',
              style: TextStyle(color: AppColors.onSurfaceMuted),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _showPlayerSelection,
              icon: const Icon(Icons.person_search),
              label: const Text('Choose a player…'),
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
      externalNavigateFen: _navigateFen,
      externalNavigateGeneration: _navigateGeneration,
      isLoading: _isAnalyzing,
      onAnalyze: _analyzeBothColors,
      hasEvals: _hasEvals,
      onAnalyzeWithEngine: _canStartEngineJob ? _showWeaknessConfig : null,
      playerName: _currentPlayer?.username,
      analysisPgnPath: _analysisPgnPath,
      holesResult: _holesResults[_playerIsWhite],
      holesLiveFindings: huntOnDisplayedColor ? _holesLive : const [],
      isHoleHunting: huntOnDisplayedColor,
      holesProgress: huntOnDisplayedColor ? _holesProgress : null,
      holesProbesSkipped: _probesSkipped && _huntIsWhite == _playerIsWhite,
      onHolesResultChanged: _onHolesResultChanged,
      onStartHoleHunt: _canStartEngineJob ? _showHoleHuntConfig : null,
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
        ' · ${p.rangeDescription}$dl$_prepSubtitle';
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

    if (result != null && mounted) await _selectPlayer(result);
  }

  /// Make [player] the analysed player: stop whatever is running for the
  /// previous one, resolve their place in the opponents directory, build.
  @override
  Future<void> _selectPlayer(AnalysisPlayerInfo player) async {
    _cancelEvalAnalysis();
    if (_isHunting) _cancelHoleHunt();
    setState(() {
      _currentPlayer = player;
      _resetAnalysisState();
      _resolvePrep();
    });
    await _analyzeBothColors();
  }

  /// Clear all per-player analysis state (both colours + evals + holes).
  void _resetAnalysisState() {
    _analysisTask?.cancel();
    _analysisPgnPath = null;
    _positionAnalysis = null;
    _openingTree = null;
    _whiteAnalysis = null;
    _blackAnalysis = null;
    _whiteTree = null;
    _blackTree = null;
    _playerIsWhite = true;
    _engineEvals = [];
    _analysisFingerprint = null;
    _holesResults[true] = null;
    _holesResults[false] = null;
    _holesConfigs[true] = null;
    _holesConfigs[false] = null;
    _holesLive = [];
    _holesProgress = null;
    _probesSkipped = false;
  }

  // ── Re-download games ───────────────────────────────────────────

  /// Fetch this player's games again — range and time controls are asked
  /// for, site and username are not — then rebuild both trees. Engine evals
  /// and hunt results are cleared: they described the old game-set.
  Future<void> _showRedownload() async {
    final player = _currentPlayer;
    if (player == null || !player.canRedownload) return;

    final config = await showDialog<AnalysisPlayerInfo>(
      context: context,
      builder: (_) => AnalysisDownloadDialog(player: player),
    );
    if (config == null || !mounted) return;

    _cancelEvalAnalysis();
    if (_isHunting) _cancelHoleHunt();
    _analysisTask?.cancel();

    final saved = await PlayerDownloadRunner(
      _gamesService,
    ).downloadOne(context, config);
    if (!saved || !mounted) return;

    final updated = await _gamesService.findExistingPlayer(
      config.platform,
      config.username,
    );
    if (!mounted) return;
    setState(() {
      _currentPlayer = updated ?? config;
      _resetAnalysisState();
    });
    await _analyzeBothColors();
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

  Future<void> _analyzeBothColors() async {
    final player = _currentPlayer;
    if (player == null) return;

    _analysisTask?.cancel();
    final task = _analysisTask = IsolateTask();
    bool isCurrent() =>
        mounted && !task.isCancelled && identical(_analysisTask, task);

    setState(() {
      _isAnalyzing = true;
      _analysisPhase = 'Loading games';
      _analysisCurrent = 0;
      _analysisTotal = 0;
    });

    try {
      final corpus = await _gamesService.loadCorpus(
        player.platform,
        player.username,
      );
      if (!isCurrent()) return;
      if (corpus == null) throw StateError('Player games are not available.');
      final pgnPath = corpus.pgnPath;
      final whiteCachePath = corpus.cachePath('white_analysis.json');
      final blackCachePath = corpus.cachePath('black_analysis.json');

      if (!await File(pgnPath).exists()) {
        if (isCurrent()) {
          _showError(
            'No games found. Please re-download games for this player.',
          );
          setState(() => _isAnalyzing = false);
        }
        return;
      }
      if (!isCurrent()) return;
      _analysisPgnPath = pgnPath;

      // Fast path: both colours restored from the stat-validated disk cache.
      var bundle = await UnifiedAnalysisBuilder.loadCachedBundle(
        task: task,
        pgnFilePath: pgnPath,
        whiteCachePath: whiteCachePath,
        blackCachePath: blackCachePath,
      );

      // Slow path: one isolate reads the file and builds both colours in a
      // single pass, persisting the cache for next time.
      if (!isCurrent()) return;
      if (bundle == null) {
        if (isCurrent()) {
          setState(() => _analysisPhase = 'Analyzing games');
        }
        bundle = await UnifiedAnalysisBuilder.buildBothInIsolate(
          task: task,
          pgnFilePath: pgnPath,
          username: player.username,
          onProgress: (current, total) {
            if (isCurrent()) _onBuildProgress(current, total);
          },
          whiteCachePath: whiteCachePath,
          blackCachePath: blackCachePath,
        );
      }

      // Guard: the user may have selected a different player while the
      // (possibly minutes-long) build ran — installing this bundle would
      // show the old player's data under the new player's name.
      if (!isCurrent()) return;
      if (await _gamesService.corpusFingerprint(
            player.platform,
            player.username,
          ) !=
          corpus.fingerprint) {
        throw StateError(
          'Player games changed while the tree was built. Reopen this player.',
        );
      }
      if (!isCurrent()) return;
      final result = bundle;
      setState(() {
        _analysisFingerprint = corpus.fingerprint;
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
      if (!isCurrent()) return;
      await _loadHolesReports();
      final warning = _gamesService.storageWarning;
      if (mounted && warning != null) _showError(warning);
    } catch (e) {
      if (isCurrent()) {
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
