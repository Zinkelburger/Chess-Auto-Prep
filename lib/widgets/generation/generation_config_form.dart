import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../constants/engine_defaults.dart';
import '../../features/coverage/services/coverage_service.dart';
import '../../models/eval_database_settings.dart';
import '../../models/pgn_source.dart';
import '../../services/eval/cdbdirect_eval_provider.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../lichess_db_info_icon.dart';
import '../lichess_db_selector.dart';
import '../pgn_sources_panel.dart';
import 'engine_resources_section.dart';
import 'eval_sources_section.dart';

part 'generation_config_form_state_base.dart';
part 'generation_config_form_descriptions.dart';
part 'generation_config_form_fields.dart';
part 'generation_config_form_io.dart';

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

class GenerationConfigFormState extends _GenerationConfigFormStateBase
    with
        _GenerationConfigDescriptions,
        _GenerationConfigFields,
        _GenerationConfigIo {
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
    _fastAltGapCtrl.dispose();
    _maiaPriorGamesCtrl.dispose();
    _coverMinProbCtrl.dispose();
    _verifyDepthCtrl.dispose();
    _setupMovesCtrl.dispose();
    _setupToleranceCtrl.dispose();
    _targetLinesCtrl.dispose();
    super.dispose();
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
        Text(_buildModeDescription(), style: AppTextStyles.caption),
        if (_buildMode != BuildMode.trapFinder) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.warningTint,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.25),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.tips_and_updates_outlined,
                  size: 14,
                  color: AppColors.warning,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Traps are automatically detected after building. '
                    'Browse them in the Lines pane.',
                    style: TextStyle(fontSize: 11, color: AppColors.warning),
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
            style: AppTextStyles.caption.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 6),
          PgnSourcesPanel(
            key: _pgnSourcesKey,
            initialSources: null,
            onSourcesChanged: (sources) {
              _pgnFilePaths
                ..clear()
                ..addAll(
                  sources
                      .where((s) => s.filePath != null)
                      .map((s) => s.filePath!),
                );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(
                _dbMinGamesCtrl,
                'Min Games per Move',
                tooltip:
                    'Opponent moves need at least this many games '
                    'in your PGN database to be explored',
              ),
              _numField(
                _dbMinProbCtrl,
                'Min Move Probability',
                tooltip:
                    'Minimum move frequency (0–1) to include '
                    'an opponent reply',
              ),
              _numField(
                _minEloCtrl,
                'Min Elo Filter',
                tooltip:
                    'Skip games where both players are below '
                    'this Elo (0 = no filter)',
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _numField(
              _maxPlyCtrl,
              'Max Depth (ply)',
              tooltip:
                  'How many half-moves deep to explore. '
                  'Higher values find deeper lines but take longer.',
            ),
            if (_buildMode == BuildMode.stockfishExpectimax)
              _numField(
                _engineDepthCtrl,
                'Engine Depth',
                tooltip:
                    'Stockfish search depth per position. '
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
                color: AppColors.onSurfaceSoft,
              ),
              const SizedBox(width: 4),
              const Text(
                'Advanced settings',
                style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
              ),
            ],
          ),
        ),
        Visibility(
          visible: _showAdvanced,
          maintainState: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionHeader('Play style'),
              TextField(
                controller: _setupMovesCtrl,
                decoration: InputDecoration(
                  labelText: 'Preferred Setup (SAN moves)',
                  hintText: 'e.g. Be3 Qd2 f3 O-O-O h4 Nh3',
                  helperText:
                      'System to play whenever sound: legal setup moves are '
                      'evaluated as candidates, and selection prefers them '
                      'within the tolerance. Empty = off.',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: Tooltip(
                    message:
                        'An unordered set — the moves can happen in any order.\n'
                        'At each of our positions, every setup move that is\n'
                        'legal there (once played, e.g. Be3, it stops being\n'
                        'legal and drops out) is evaluated and added as a\n'
                        'candidate if it stays within Max Eval Loss of the\n'
                        'best move.\n'
                        '\n'
                        'Selection then prefers a setup move whose eval is\n'
                        'within Setup Tolerance of the best candidate over\n'
                        'the plain expectimax pick. Expectimax values are\n'
                        'never modified — if the opponent makes the setup\n'
                        'too costly, no move qualifies and the repertoire\n'
                        'deviates automatically.',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              _numField(
                _setupToleranceCtrl,
                'Setup Tolerance (cp)',
                tooltip:
                    'Max centipawns a preferred-setup move may lose vs the\n'
                    'best candidate and still be chosen for consistency.',
              ),
              const SizedBox(height: 8),
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
                            () => _preferNovelties = !_preferNovelties,
                          ),
                    child: const Text(
                      'Prefer novelties',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'Favor less-played moves that are still sound.\n'
                        'Uses Maia/Lichess frequency data to boost unusual lines.',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
              _sectionHeader('Line selection'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<SelectionMode>(
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
                              if (v != null) {
                                setState(() => _selectionMode = v);
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message:
                        'Separate from Build Mode: the build explores and\n'
                        'evaluates candidate moves; line selection decides\n'
                        'which candidate becomes your repertoire move at\n'
                        'each position.',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _selectionModeDescription(),
                style: AppTextStyles.caption.copyWith(fontSize: 11),
              ),
              _sectionHeader('Thresholds'),
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
              const SizedBox(height: 8),
              _toggleSwitch(
                'Relative Eval',
                _relativeEval,
                (v) {
                  setState(() => _relativeEval = v);
                },
                tooltip:
                    'Thresholds are relative to the root eval (default).\n'
                    'Turn off to use absolute centipawn limits from Min/Max Eval.',
              ),
              _sectionHeader('Opponent model'),
              Row(
                children: [
                  const Text(
                    'Opponent moves: Maia',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'Maia neural network is the default opponent model.\n'
                        'You can override this with a Lichess database\n'
                        'in the settings below.',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
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
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'Opponent DB override',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'Override Maia with a Lichess database for opponent\n'
                        'move frequencies. Maia remains the fallback for\n'
                        'positions with no database data.',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
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
                        : (_) => setState(
                            () =>
                                _lichessDbOverride ??= LichessDatabase.lichess,
                          ),
                  ),
                  const LichessDbInfoIcon(size: 14),
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
              _sectionHeader('Search tuning'),
              DropdownButtonFormField<SearchAlgorithm>(
                initialValue: _searchAlgorithm,
                decoration: const InputDecoration(
                  labelText: 'Search Algorithm',
                  border: OutlineInputBorder(),
                  isDense: true,
                  helperText:
                      'Fast: best-first with priority-scaled pruning — rare '
                      'lines get a lighter search, coverage floor still '
                      'guaranteed. Pure: exhaustive BFS, full search '
                      'everywhere (slowest).',
                  helperMaxLines: 4,
                ),
                items: const [
                  DropdownMenuItem(
                    value: SearchAlgorithm.fast,
                    child: Text('Fast Expectimax (recommended)'),
                  ),
                  DropdownMenuItem(
                    value: SearchAlgorithm.pure,
                    child: Text('Pure Expectimax (exhaustive)'),
                  ),
                ],
                onChanged: widget.isGenerating
                    ? null
                    : (v) => setState(
                        () => _searchAlgorithm = v ?? SearchAlgorithm.fast,
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    value: _wideOpening,
                    onChanged: widget.isGenerating
                        ? null
                        : (v) => setState(() => _wideOpening = v ?? false),
                  ),
                  GestureDetector(
                    onTap: widget.isGenerating
                        ? null
                        : () => setState(() => _wideOpening = !_wideOpening),
                    child: const Text(
                      'Wide opening search',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'Explore extra candidate moves for the first few of our\n'
                        'moves (both Fast and Pure), then narrow deeper lines.\n'
                        'Broadens the opening so alternatives and novelties are\n'
                        'not missed; costs some build time. Off = only the very\n'
                        'first move gets the wide sweep.',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField(
                    _multipvCtrl,
                    'MultiPV',
                    tooltip: 'Candidate moves evaluated per our-move node',
                  ),
                  _numField(
                    _oppMaxChildrenCtrl,
                    'Opp Max Children',
                    tooltip: 'Maximum opponent replies explored per position',
                  ),
                  _numField(
                    _oppMassTargetCtrl,
                    'Opp Mass Target',
                    tooltip:
                        'Stop adding opponent moves after this probability mass is covered',
                  ),
                  _numField(
                    _leafConfidenceCtrl,
                    'Leaf Confidence (0-1)',
                    tooltip:
                        'Trust in engine eval at leaves; lower blends toward 0.5',
                  ),
                  _numField(
                    _ourAltDiscountCtrl,
                    'Alt Discount (0-1)',
                    tooltip:
                        'Best-first priority multiplier for our non-best candidates.\n'
                        'Lower = more budget on the mainline, less on alternatives.',
                  ),
                  _numField(
                    _fastAltGapCtrl,
                    'Alt Gap (cp)',
                    tooltip:
                        'Fast Expectimax only: our alternatives more than this\n'
                        'many centipawns behind the best candidate stay as\n'
                        'evaluated leaves instead of growing a subtree.\n'
                        '0 disables. Ignored in trappy selection mode.',
                  ),
                  _numField(
                    _maiaPriorGamesCtrl,
                    'Maia Prior (games)',
                    tooltip:
                        'Dirichlet prior weight λ blending DB opponent frequencies\n'
                        'with Maia: p = (count + λ·maia) / (N + λ). 0 disables.',
                  ),
                  _numField(
                    _coverMinProbCtrl,
                    'Cover Min Prob (0-1)',
                    tooltip:
                        'No-silent-holes floor: every opponent reply at/above this\n'
                        'local probability gets a repertoire answer, even in lines\n'
                        'the search budget would otherwise skip. 0 disables.',
                  ),
                ],
              ),
              _sectionHeader('Verification'),
              Row(
                children: [
                  _toggleSwitch(
                    'Verify Final Output',
                    _verifyFinal,
                    (v) {
                      setState(() => _verifyFinal = v);
                    },
                    tooltip:
                        'Re-check every selected repertoire move at the verify\n'
                        'depth after selection; moves that lose more than Max Eval\n'
                        'Loss vs a deep-checked alternative are replaced. Gives the\n'
                        'export a depth guarantee at the cost of extra engine time.',
                  ),
                  const SizedBox(width: 16),
                  _numField(
                    _verifyDepthCtrl,
                    'Verify Depth (0=auto)',
                    tooltip:
                        'Stockfish depth for the final verification pass.\n'
                        '0 = automatic (eval depth + 6, at least 20).',
                  ),
                ],
              ),
              _sectionHeader('PGN export'),
              _numField(
                _targetLinesCtrl,
                'Max unique lines (0 = keep all)',
                tooltip:
                    'Prune similar lines before export: lines that differ only\n'
                    'in opponent moves (we play the same moves in each) collapse\n'
                    'to one representative, and the survivors are the lines that\n'
                    'teach the most new, likely, sharpest of our moves — up to\n'
                    'this many. 0 exports every extracted line.',
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Rank lines by cumulative probability',
                  style: TextStyle(fontSize: 13),
                ),
                value: _rankLinesByImportance,
                onChanged: widget.isGenerating
                    ? null
                    : (v) => setState(() => _rankLinesByImportance = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Annotate move probabilities',
                  style: TextStyle(fontSize: 13),
                ),
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
                      DropdownMenuItem(value: true, child: Text('Maia only')),
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
              const SizedBox(height: 20),
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
}
