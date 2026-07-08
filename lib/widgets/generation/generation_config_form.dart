import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../constants/engine_defaults.dart';
import '../../features/coverage/services/coverage_service.dart';
import '../../models/eval_database_settings.dart';
import '../../models/pgn_source.dart';
import '../../services/eval/cdbdirect_eval_provider.dart';
import '../../services/generation/generation_config.dart';
import '../lichess_db_info_icon.dart';
import '../lichess_db_selector.dart';
import '../pgn_sources_panel.dart';
import 'engine_resources_section.dart';
import 'eval_sources_section.dart';

/// Settings form for repertoire tree generation (build mode, thresholds, eval sources).
class GenerationConfigForm extends StatefulWidget {
  final TreeBuildConfig? initialConfig;
  final bool isGenerating;
  final bool playAsWhite;

  const GenerationConfigForm({
    super.key,
    this.initialConfig,
    required this.isGenerating,
    required this.playAsWhite,
  });

  @override
  State<GenerationConfigForm> createState() => GenerationConfigFormState();
}

class GenerationConfigFormState extends State<GenerationConfigForm> {
  final GlobalKey<EvalSourcesSectionState> _evalSourcesKey =
      GlobalKey<EvalSourcesSectionState>();
  final GlobalKey<PgnSourcesPanelState> _pgnSourcesKey =
      GlobalKey<PgnSourcesPanelState>();
  bool _cdbDirectAvailable = false;

  final TextEditingController _cutoffCtrl = TextEditingController(text: '0.01');
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '20');
  final TextEditingController _engineDepthCtrl = TextEditingController(
    text: '$kDefaultGenerationEvalDepth',
  );
  late final TextEditingController _engineThreadsCtrl;
  final TextEditingController _evalGuardCtrl =
      TextEditingController(text: '30');
  late final TextEditingController _minEvalCtrl;
  late final TextEditingController _maxEvalCtrl;
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2200');

  final TextEditingController _multipvCtrl = TextEditingController(text: '4');
  final TextEditingController _oppMaxChildrenCtrl =
      TextEditingController(text: '4');
  final TextEditingController _oppMassTargetCtrl =
      TextEditingController(text: '0.80');
  final TextEditingController _leafConfidenceCtrl =
      TextEditingController(text: '1.0');
  final TextEditingController _ourAltDiscountCtrl =
      TextEditingController(text: '0.25');
  final TextEditingController _maiaPriorGamesCtrl =
      TextEditingController(text: '30');
  final TextEditingController _coverMinProbCtrl =
      TextEditingController(text: '0.05');
  final TextEditingController _verifyDepthCtrl =
      TextEditingController(text: '0');
  final TextEditingController _setupMovesCtrl = TextEditingController();
  final TextEditingController _setupToleranceCtrl =
      TextEditingController(text: '30');
  bool _bestFirst = true;
  bool _verifyFinal = true;

  final List<String> _pgnFilePaths = [];
  final TextEditingController _dbMinGamesCtrl =
      TextEditingController(text: '5');
  final TextEditingController _dbMinProbCtrl =
      TextEditingController(text: '0.05');
  final TextEditingController _minEloCtrl = TextEditingController(text: '0');

  LichessDatabase? _lichessDbOverride;
  bool _relativeEval = true;
  bool _preferNovelties = false;

  bool _rankLinesByImportance = true;
  bool _annotateMoveProbabilities = true;
  bool _annotateMaiaOnly = true;

  final TextEditingController _lichessMinGamesCtrl =
      TextEditingController(text: '10');
  final Set<String> _lichessSpeeds = {'blitz', 'rapid', 'classical'};
  final Set<String> _lichessRatings = {'2000', '2200', '2500'};

  SelectionMode _selectionMode = SelectionMode.expectimax;
  BuildMode _buildMode = BuildMode.stockfishExpectimax;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    _engineThreadsCtrl = TextEditingController(
      text: defaultEngineThreads().toString(),
    );
    _minEvalCtrl = TextEditingController(
      text: widget.playAsWhite ? '0' : '-100',
    );
    _maxEvalCtrl = TextEditingController(
      text: widget.playAsWhite ? '200' : '100',
    );
    if (widget.initialConfig != null) {
      _applyInitialConfig(widget.initialConfig!);
    }
    CdbDirectEvalProvider.probeAvailability().then((available) {
      if (!mounted) return;
      setState(() => _cdbDirectAvailable = available);
    });
  }

  @override
  void didUpdateWidget(covariant GenerationConfigForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialConfig != oldWidget.initialConfig &&
        widget.initialConfig != null) {
      _applyInitialConfig(widget.initialConfig!);
    }
  }

  void _applyInitialConfig(TreeBuildConfig config) {
    _cutoffCtrl.text = (config.minProbability * 100).toString();
    _maxPlyCtrl.text = config.maxPly.toString();
    _engineDepthCtrl.text = config.evalDepth.toString();
    _engineThreadsCtrl.text = config.engineThreads > 0
        ? config.engineThreads.toString()
        : defaultEngineThreads().toString();
    _evalGuardCtrl.text = config.maxEvalLossCp.toString();
    _minEvalCtrl.text = config.minEvalCp.toString();
    _maxEvalCtrl.text = config.maxEvalCp.toString();
    _maiaEloCtrl.text = config.maiaElo.toString();
    _multipvCtrl.text = config.ourMultipv.toString();
    _oppMaxChildrenCtrl.text = config.oppMaxChildren.toString();
    _oppMassTargetCtrl.text = config.oppMassTarget.toString();
    _leafConfidenceCtrl.text = config.leafConfidence.toString();
    _ourAltDiscountCtrl.text = config.ourAltDiscount.toString();
    _maiaPriorGamesCtrl.text = config.maiaPriorGames.toString();
    _coverMinProbCtrl.text = config.coverMinProb.toString();
    _verifyDepthCtrl.text = config.verifyDepth.toString();
    _setupMovesCtrl.text = config.setupMoves;
    _setupToleranceCtrl.text = config.setupToleranceCp.toString();
    _bestFirst = config.bestFirst;
    _verifyFinal = config.verifyFinal;
    _dbMinGamesCtrl.text = config.dbMinGames.toString();
    _dbMinProbCtrl.text = config.dbMinProb.toString();
    _minEloCtrl.text = config.minElo.toString();
    _lichessMinGamesCtrl.text = config.minGames.toString();
    _buildMode = config.buildMode;
    _selectionMode = config.selectionMode;
    _relativeEval = config.relativeEval;
    _preferNovelties = config.noveltyWeight > 0;
    _rankLinesByImportance = config.rankLinesByImportance;
    _annotateMoveProbabilities = config.annotateMoveProbabilities;
    _annotateMaiaOnly = config.annotateMaiaOnly;
    _pgnFilePaths
      ..clear()
      ..addAll(config.pgnFilePaths);
    if (config.useLichessDb) {
      _lichessDbOverride =
          config.useMasters ? LichessDatabase.masters : LichessDatabase.lichess;
    } else {
      _lichessDbOverride = null;
    }
    _lichessSpeeds
      ..clear()
      ..addAll(config.speeds.split(',').where((s) => s.isNotEmpty));
    _lichessRatings
      ..clear()
      ..addAll(config.ratingRange.split(',').where((s) => s.isNotEmpty));
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _maxPlyCtrl.dispose();
    _engineDepthCtrl.dispose();
    _engineThreadsCtrl.dispose();
    _evalGuardCtrl.dispose();
    _minEvalCtrl.dispose();
    _maxEvalCtrl.dispose();
    _maiaEloCtrl.dispose();
    _lichessMinGamesCtrl.dispose();
    _dbMinGamesCtrl.dispose();
    _dbMinProbCtrl.dispose();
    _minEloCtrl.dispose();
    _multipvCtrl.dispose();
    _oppMaxChildrenCtrl.dispose();
    _oppMassTargetCtrl.dispose();
    _leafConfidenceCtrl.dispose();
    _ourAltDiscountCtrl.dispose();
    _maiaPriorGamesCtrl.dispose();
    _coverMinProbCtrl.dispose();
    _verifyDepthCtrl.dispose();
    _setupMovesCtrl.dispose();
    _setupToleranceCtrl.dispose();
    super.dispose();
  }

  /// Pre-configure DB Explorer mode with the given PGN file paths and
  /// minimum game count.
  void seedDbExplorer({
    required List<String> pgnPaths,
    int minGames = 1,
  }) {
    setState(() {
      _buildMode = BuildMode.dbExplorer;
      _pgnFilePaths
        ..clear()
        ..addAll(pgnPaths);
      _dbMinGamesCtrl.text = minGames.toString();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final panelState = _pgnSourcesKey.currentState;
      if (panelState != null) {
        final sources = pgnPaths
            .map((path) => PgnSource(
                  id: PgnSource.generateId(),
                  name: p.basenameWithoutExtension(path),
                  filePath: path,
                ))
            .toList();
        panelState.seedSources(sources);
      }
    });
  }

  void setMaxPly(int maxPly) {
    _maxPlyCtrl.text = maxPly.toString();
  }

  void resetChessDbApiUsageForBuild(int quota) {
    _evalSourcesKey.currentState?.resetChessDbApiUsageForBuild(quota);
  }

  void updateChessDbApiUsage(int usedToday, int quotaLimit) {
    _evalSourcesKey.currentState?.updateChessDbApiUsage(usedToday, quotaLimit);
  }

  String selectionModeDescription() => _selectionModeDescription();

  /// Whether the current configuration is ready to start a build.
  bool get canStart => validateBeforeStart() == null;

  /// Returns an error message when the current settings cannot start a build.
  String? validateBeforeStart() {
    if (_buildMode == BuildMode.trapFinder) {
      return '${_buildModeLabel(_buildMode)} is not yet available in the app.';
    }
    if (_buildMode == BuildMode.dbExplorer && _pgnFilePaths.isEmpty) {
      final sources = _pgnSourcesKey.currentState?.sources ?? [];
      if (sources.isEmpty) {
        return 'Add at least one PGN file first. Use the picker above to '
            'attach .pgn files with your games.';
      }
    }
    final evalSources = _evalSourcesKey.currentState;
    if (_buildMode == BuildMode.maiaDbExplore &&
        !(evalSources?.enableLocalChessDb ?? false) &&
        !(evalSources?.enableChessDbApi ?? false) &&
        !EvalDatabaseSettings.instance.enableCdbDirect) {
      return 'DB Win Rate mode needs at least one eval source enabled '
          '(local ChessDB, cdbdirect, or ChessDB API).';
    }
    return null;
  }

  TreeBuildConfig toConfig({
    required String startFen,
    required bool playAsWhite,
  }) {
    final evalDepth = int.tryParse(_engineDepthCtrl.text.trim()) ??
        kDefaultGenerationEvalDepth;
    final rawThreads = int.tryParse(_engineThreadsCtrl.text.trim());
    final engineThreads = rawThreads != null
        ? clampEngineThreads(rawThreads)
        : defaultEngineThreads();
    final eval = _evalSourcesKey.currentState;
    final minAcceptableRaw = eval?.minAcceptableEvalDepthRaw ?? '';
    final minAcceptableDepth = minAcceptableRaw.isEmpty
        ? 0
        : (int.tryParse(minAcceptableRaw) ?? evalDepth);

    final dbSettings = EvalDatabaseSettings.instance;

    final isTrappyMode = _selectionMode == SelectionMode.trappy;
    final userMaxEvalLoss = int.tryParse(_evalGuardCtrl.text.trim()) ?? 30;
    final userMinEval =
        int.tryParse(_minEvalCtrl.text.trim()) ?? (playAsWhite ? 0 : -100);

    return TreeBuildConfig(
      startFen: startFen,
      playAsWhite: playAsWhite,
      minProbability: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: 0.01,
      ),
      maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 20,
      buildMode: _buildMode,
      pgnFilePaths: List.unmodifiable(_pgnFilePaths),
      dbMinGames: int.tryParse(_dbMinGamesCtrl.text.trim()) ?? 5,
      dbMinProb: double.tryParse(_dbMinProbCtrl.text.trim()) ?? 0.05,
      minElo: int.tryParse(_minEloCtrl.text.trim()) ?? 0,
      evalDepth: evalDepth,
      engineThreads: engineThreads,
      maxEvalLossCp: isTrappyMode
          ? (userMaxEvalLoss < 100 ? 100 : userMaxEvalLoss)
          : userMaxEvalLoss,
      minEvalCp: isTrappyMode
          ? (playAsWhite
              ? (userMinEval > -100 ? -100 : userMinEval)
              : (userMinEval > -300 ? -300 : userMinEval))
          : userMinEval,
      maxEvalCp:
          int.tryParse(_maxEvalCtrl.text.trim()) ?? (playAsWhite ? 200 : 100),
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
      maiaOnly: _lichessDbOverride == null,
      rankLinesByImportance: _rankLinesByImportance,
      annotateMoveProbabilities: _annotateMoveProbabilities,
      annotateMaiaOnly: _annotateMaiaOnly,
      ourMultipv: int.tryParse(_multipvCtrl.text.trim()) ?? 4,
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 4,
      oppMassTarget: double.tryParse(_oppMassTargetCtrl.text.trim()) ?? 0.80,
      bestFirst: _bestFirst,
      ourAltDiscount:
          (double.tryParse(_ourAltDiscountCtrl.text.trim()) ?? 0.25)
              .clamp(0.0, 1.0),
      maiaPriorGames:
          double.tryParse(_maiaPriorGamesCtrl.text.trim()) ?? 30.0,
      coverMinProb: (double.tryParse(_coverMinProbCtrl.text.trim()) ?? 0.05)
          .clamp(0.0, 1.0),
      verifyFinal: _verifyFinal,
      verifyDepth:
          (int.tryParse(_verifyDepthCtrl.text.trim()) ?? 0).clamp(0, 40),
      setupMoves: _setupMovesCtrl.text.trim(),
      setupToleranceCp:
          (int.tryParse(_setupToleranceCtrl.text.trim()) ?? 30).clamp(0, 500),
      useLichessDb: _lichessDbOverride != null,
      useMasters: _lichessDbOverride == LichessDatabase.masters,
      speeds: _lichessSpeeds.join(','),
      ratingRange: (_lichessRatings.toList()..sort()).join(','),
      minGames: int.tryParse(_lichessMinGamesCtrl.text.trim()) ?? 10,
      relativeEval: _relativeEval,
      selectionMode: _selectionMode,
      noveltyWeight: _preferNovelties ? 60 : 0,
      leafConfidence: double.tryParse(_leafConfidenceCtrl.text.trim()) ?? 1.0,
      enableCdbDirect: _cdbDirectAvailable && dbSettings.enableCdbDirect,
      cdbDirectPath: _cdbDirectAvailable ? dbSettings.cdbDirectPath : '',
      cdbDirectReadAhead: _cdbDirectAvailable && dbSettings.cdbDirectReadAhead,
      batchEvalLookups:
          _cdbDirectAvailable && (eval?.batchEvalLookups ?? false),
      enableLocalChessDb: eval?.enableLocalChessDb ?? false,
      localChessDbPath: eval?.localChessDbPath ?? '',
      enableChessDbApi: eval?.enableChessDbApi ?? false,
      chessDbApiDailyQuota: eval?.chessDbApiDailyQuota ?? 5000,
      chessDbApiConcurrency: eval?.chessDbApiConcurrency ?? 2,
      enableExtEvalSubtreeSkip: eval?.enableExtEvalSubtreeSkip ?? true,
      minAcceptableEvalDepth: minAcceptableDepth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<BuildMode>(
          initialValue: _buildMode,
          decoration: const InputDecoration(
            labelText: 'Build Mode',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: const [
            DropdownMenuItem(
              value: BuildMode.stockfishExpectimax,
              child: Text('Stockfish Expectimax (recommended)'),
            ),
            DropdownMenuItem(
              value: BuildMode.maiaDbExplore,
              child: Text('DB Win Rate Only (no Stockfish)'),
            ),
            DropdownMenuItem(
              value: BuildMode.dbExplorer,
              child: Text('From Added PGN Files'),
            ),
          ],
          onChanged: widget.isGenerating
              ? null
              : (v) {
                  if (v != null) setState(() => _buildMode = v);
                },
        ),
        const SizedBox(height: 4),
        Text(
          _buildModeDescription(),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        if (_buildMode != BuildMode.trapFinder) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.tips_and_updates_outlined,
                    size: 14, color: Colors.amber[600]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Traps are automatically detected after building. '
                    'Browse them in the Lines tab.',
                    style: TextStyle(fontSize: 11, color: Colors.amber[200]),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (_buildMode == BuildMode.dbExplorer) ...[
          Text(
            'Add PGN files with the picker below. Lines already in your '
            'repertoire are not used for this build mode.',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 6),
          PgnSourcesPanel(
            key: _pgnSourcesKey,
            initialSources: null,
            onSourcesChanged: (sources) {
              _pgnFilePaths
                ..clear()
                ..addAll(sources
                    .where((s) => s.filePath != null)
                    .map((s) => s.filePath!));
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_dbMinGamesCtrl, 'Min Games per Move',
                  tooltip: 'Opponent moves need at least this many games '
                      'in your PGN database to be explored'),
              _numField(_dbMinProbCtrl, 'Min Move Probability',
                  tooltip: 'Minimum move frequency (0–1) to include '
                      'an opponent reply'),
              _numField(_minEloCtrl, 'Min Elo Filter',
                  tooltip: 'Skip games where both players are below '
                      'this Elo (0 = no filter)'),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _numField(_maxPlyCtrl, 'Max Depth (ply)',
                tooltip: 'How many half-moves deep to explore. '
                    'Higher values find deeper lines but take longer.'),
            if (_buildMode == BuildMode.stockfishExpectimax)
              _numField(
                _engineDepthCtrl,
                'Engine Depth',
                tooltip: 'Stockfish search depth per position. '
                    'Higher is more accurate but slower. '
                    'Default 14 is a good balance.',
              ),
          ],
        ),
        if (_buildMode == BuildMode.stockfishExpectimax ||
            _buildMode == BuildMode.dbExplorer) ...[
          const SizedBox(height: 12),
          EngineResourcesSection(
            threadsController: _engineThreadsCtrl,
            isGenerating: widget.isGenerating,
            isDbExplorer: _buildMode == BuildMode.dbExplorer,
          ),
        ],
        const SizedBox(height: 12),
        InkWell(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          child: Row(
            children: [
              Icon(
                _showAdvanced ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: Colors.grey[400],
              ),
              const SizedBox(width: 4),
              Text('Advanced settings',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400])),
            ],
          ),
        ),
        Visibility(
          visible: _showAdvanced,
          maintainState: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              DropdownButtonFormField<SelectionMode>(
                initialValue: _selectionMode,
                decoration: const InputDecoration(
                  labelText: 'Line Selection',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: SelectionMode.expectimax,
                    child: Text('Expectimax (recommended)'),
                  ),
                  DropdownMenuItem(
                    value: SelectionMode.engineOnly,
                    child: Text('Engine Best Move'),
                  ),
                  DropdownMenuItem(
                    value: SelectionMode.dbWinRateOnly,
                    child: Text('Database Win Rate'),
                  ),
                  DropdownMenuItem(
                    value: SelectionMode.playable,
                    child: Text('Balanced (strength + ease)'),
                  ),
                  DropdownMenuItem(
                    value: SelectionMode.trappy,
                    child: Text('Trappy (maximize opponent mistakes)'),
                  ),
                ],
                onChanged: widget.isGenerating
                    ? null
                    : (v) {
                        if (v != null) setState(() => _selectionMode = v);
                      },
              ),
              const SizedBox(height: 4),
              Text(
                _selectionModeDescription(),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Text('Thresholds', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField(_cutoffCtrl, 'Cum Prob Cutoff (%)'),
                  _numField(_evalGuardCtrl, 'Max Eval Loss (cp)'),
                  _numField(_minEvalCtrl, 'Min Eval For Us (cp)'),
                  _numField(_maxEvalCtrl, 'Max Eval For Us (cp)'),
                  _numField(_maiaEloCtrl, 'Maia Elo'),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Opponent moves: Maia',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'Maia neural network is the default opponent model.\n'
                        'You can override this with a Lichess database\n'
                        'in the settings below.',
                    child: Icon(Icons.info_outline,
                        size: 16, color: Colors.grey[500]),
                  ),
                  if (_lichessDbOverride != null) ...[
                    const SizedBox(width: 8),
                    Chip(
                      label: Text(
                        _lichessDbOverride == LichessDatabase.masters
                            ? 'Overridden: Lichess Masters'
                            : 'Overridden: Lichess Players',
                        style: const TextStyle(fontSize: 11),
                      ),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: widget.isGenerating
                          ? null
                          : () => setState(() => _lichessDbOverride = null),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Checkbox(
                    value: _preferNovelties,
                    onChanged: widget.isGenerating
                        ? null
                        : (v) => setState(() => _preferNovelties = v ?? false),
                  ),
                  GestureDetector(
                    onTap: widget.isGenerating
                        ? null
                        : () => setState(
                            () => _preferNovelties = !_preferNovelties),
                    child: const Text(
                      'Prefer novelties',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Favor less-played moves that are still sound.\n'
                        'Uses Maia/Lichess frequency data to boost unusual lines.',
                    child: Icon(Icons.info_outline,
                        size: 16, color: Colors.grey[500]),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('PGN export', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Rank lines by cumulative probability',
                    style: TextStyle(fontSize: 13)),
                value: _rankLinesByImportance,
                onChanged: widget.isGenerating
                    ? null
                    : (v) => setState(() => _rankLinesByImportance = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Annotate move probabilities',
                    style: TextStyle(fontSize: 13)),
                value: _annotateMoveProbabilities,
                onChanged: widget.isGenerating
                    ? null
                    : (v) => setState(() => _annotateMoveProbabilities = v),
              ),
              if (_annotateMoveProbabilities)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 8),
                  child: DropdownButtonFormField<bool>(
                    initialValue: _annotateMaiaOnly,
                    decoration: const InputDecoration(
                      labelText: 'Probability source',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: true,
                        child: Text('Maia only'),
                      ),
                      DropdownMenuItem(
                        value: false,
                        child: Text('Lichess DB + Maia fallback'),
                      ),
                    ],
                    onChanged: widget.isGenerating
                        ? null
                        : (v) {
                            if (v != null) {
                              setState(() => _annotateMaiaOnly = v);
                            }
                          },
                  ),
                ),
              const SizedBox(height: 8),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField(_multipvCtrl, 'MultiPV',
                      tooltip: 'Candidate moves evaluated per our-move node'),
                  _numField(_oppMaxChildrenCtrl, 'Opp Max Children',
                      tooltip:
                          'Maximum opponent replies explored per position'),
                  _numField(_oppMassTargetCtrl, 'Opp Mass Target',
                      tooltip:
                          'Stop adding opponent moves after this probability mass is covered'),
                  _numField(_leafConfidenceCtrl, 'Leaf Confidence (0-1)',
                      tooltip:
                          'Trust in engine eval at leaves; lower blends toward 0.5'),
                  _numField(_ourAltDiscountCtrl, 'Alt Discount (0-1)',
                      tooltip:
                          'Best-first priority multiplier for our non-best candidates.\n'
                          'Lower = more budget on the mainline, less on alternatives.'),
                  _numField(_maiaPriorGamesCtrl, 'Maia Prior (games)',
                      tooltip:
                          'Dirichlet prior weight λ blending DB opponent frequencies\n'
                          'with Maia: p = (count + λ·maia) / (N + λ). 0 disables.'),
                  _numField(_coverMinProbCtrl, 'Cover Min Prob (0-1)',
                      tooltip:
                          'No-silent-holes floor: every opponent reply at/above this\n'
                          'local probability gets a repertoire answer, even in lines\n'
                          'the search budget would otherwise skip. 0 disables.'),
                  _numField(_verifyDepthCtrl, 'Verify Depth (0=auto)',
                      tooltip:
                          'Stockfish depth for the final verification pass.\n'
                          '0 = automatic (eval depth + 6, at least 20).'),
                  _numField(_setupToleranceCtrl, 'Setup Tolerance (cp)',
                      tooltip:
                          'Max centipawns a preferred-setup move may lose vs the\n'
                          'best candidate and still be chosen for consistency.'),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _setupMovesCtrl,
                decoration: const InputDecoration(
                  labelText: 'Preferred Setup (SAN moves)',
                  hintText: 'e.g. Be3 Qd2 f3 O-O-O h4 Nh3',
                  helperText:
                      'System to play whenever sound: legal setup moves are '
                      'evaluated as candidates, and selection prefers them '
                      'within the tolerance. Empty = off.',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _toggleSwitch('Best-First Search', _bestFirst, (v) {
                    setState(() => _bestFirst = v);
                  },
                      tooltip:
                          'Expand the most-reachable positions first (anytime build:\n'
                          'likely lines get explored deepest at any node budget).\n'
                          'Off = classic level-order BFS.'),
                  const SizedBox(width: 16),
                  _toggleSwitch('Verify Final Output', _verifyFinal, (v) {
                    setState(() => _verifyFinal = v);
                  },
                      tooltip:
                          'Re-check every selected repertoire move at the verify\n'
                          'depth after selection; moves that lose more than Max Eval\n'
                          'Loss vs a deep-checked alternative are replaced. Gives the\n'
                          'export a depth guarantee at the cost of extra engine time.'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _toggleSwitch('Relative Eval', _relativeEval, (v) {
                    setState(() => _relativeEval = v);
                  },
                      tooltip:
                          'Thresholds are relative to the root eval (default).\n'
                          'Turn off to use absolute centipawn limits from Min/Max Eval.'),
                  const LichessDbInfoIcon(size: 14),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Opponent DB override',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'Override Maia with a Lichess database for opponent\n'
                        'move frequencies. Maia remains the fallback for\n'
                        'positions with no database data.',
                    child: Icon(Icons.info_outline,
                        size: 16, color: Colors.grey[500]),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('None (Maia only)'),
                    selected: _lichessDbOverride == null,
                    onSelected: widget.isGenerating
                        ? null
                        : (_) => setState(() => _lichessDbOverride = null),
                  ),
                  const SizedBox(width: 4),
                  ChoiceChip(
                    label: const Text('Lichess DB'),
                    selected: _lichessDbOverride != null,
                    onSelected: widget.isGenerating
                        ? null
                        : (_) => setState(() =>
                            _lichessDbOverride ??= LichessDatabase.lichess),
                  ),
                ],
              ),
              if (_lichessDbOverride != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: LichessDbSelector(
                    database: _lichessDbOverride!,
                    onDatabaseChanged: (db) => setState(() {
                      final wasMasters =
                          _lichessDbOverride == LichessDatabase.masters;
                      final isMasters = db == LichessDatabase.masters;
                      _lichessDbOverride = db;
                      if (wasMasters != isMasters) {
                        _lichessMinGamesCtrl.text = isMasters ? '4' : '10';
                      }
                    }),
                    selectedSpeeds: _lichessSpeeds,
                    onSpeedsChanged: (s) => setState(() {
                      _lichessSpeeds
                        ..clear()
                        ..addAll(s);
                    }),
                    selectedRatings: _lichessRatings,
                    onRatingsChanged: (r) => setState(() {
                      _lichessRatings
                        ..clear()
                        ..addAll(r);
                    }),
                    minGamesController: _lichessMinGamesCtrl,
                    enabled: !widget.isGenerating,
                    compact: true,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              EvalSourcesSection(
                key: _evalSourcesKey,
                isGenerating: widget.isGenerating,
                cdbDirectAvailable: _cdbDirectAvailable,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _numField(
    TextEditingController controller,
    String label, {
    String? tooltip,
    bool enabled = true,
  }) {
    final field = SizedBox(
      width: 170,
      child: TextField(
        controller: controller,
        enabled: enabled && !widget.isGenerating,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip, child: field);
  }

  Widget _toggleSwitch(String label, bool value, ValueChanged<bool> onChanged,
      {String? tooltip}) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        Switch(
          value: value,
          onChanged: widget.isGenerating ? null : onChanged,
        ),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip, child: row);
  }

  String _buildModeLabel(BuildMode mode) {
    switch (mode) {
      case BuildMode.stockfishExpectimax:
        return 'Stockfish Expectimax';
      case BuildMode.maiaDbExplore:
        return 'DB Win Rate Only';
      case BuildMode.dbExplorer:
        return 'From Added PGN Files';
      case BuildMode.trapFinder:
        return 'Trap Finder';
    }
  }

  String _buildModeDescription() {
    switch (_buildMode) {
      case BuildMode.stockfishExpectimax:
        return 'Stockfish evaluates every position; Maia predicts opponent '
            'moves. Thorough but slower.';
      case BuildMode.maiaDbExplore:
        return 'Uses Maia neural-net moves + database win rates only — '
            'fast, no engine needed.';
      case BuildMode.dbExplorer:
        return 'Builds from PGN files you add below—not from lines already '
            'in your repertoire. Uses move frequencies from those games; '
            'engine evals added after.';
      case BuildMode.trapFinder:
        return 'Not yet available.';
    }
  }

  String _selectionModeDescription() {
    switch (_selectionMode) {
      case SelectionMode.expectimax:
        return 'Picks lines by weighing engine eval against how opponents '
            'actually play. Best overall results.';
      case SelectionMode.engineOnly:
        return 'Always picks the engine\'s top move. Strong but may choose '
            'lines that are hard to remember.';
      case SelectionMode.dbWinRateOnly:
        return 'Picks moves by practical win rate from game databases. '
            'Falls back to engine eval when no data is available.';
      case SelectionMode.playable:
        return 'Balances strength (60%) with ease of play (40%) — prefers '
            'moves that are both sound and natural to find over the board.';
      case SelectionMode.trappy:
        return 'Picks lines where opponents are most likely to blunder. '
            'Uses expected centipawn loss instead of win probability. '
            'Build tolerances are automatically widened to explore '
            'trickier positions.';
    }
  }

  double _parsePercentToFraction(
    String raw, {
    required double fallbackPercent,
  }) {
    final parsed = double.tryParse(raw.replaceAll('%', '').trim());
    final safePercent = (parsed ?? fallbackPercent).clamp(0.0, 100.0);
    return safePercent / 100.0;
  }
}