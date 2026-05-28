/// Centralized settings screen accessible from the app bar.
///
/// Groups all persistent engine configuration in a single scrollable view.
/// Uses [ListenableBuilder] so it always reflects the latest singleton state,
/// even if another UI surface mutates [EngineSettings] concurrently.
library;

import 'package:flutter/material.dart';

import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import '../models/settings_enums.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../utils/system_info.dart';
import '../widgets/eval_database_settings_panel.dart';
import '../widgets/lichess_db_selector.dart';
import '../widgets/settings/settings_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _engine = EngineSettings();
  late final TextEditingController _probStartCtrl;

  @override
  void initState() {
    super.initState();
    _probStartCtrl = TextEditingController(text: _engine.probabilityStartMoves);
  }

  @override
  void dispose() {
    _probStartCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _engine,
      builder: (context, _) {
        final cores = getLogicalCores();

        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Engine ───────────────────────────────────
              _buildEngineSection(cores),
              const SizedBox(height: 8),

              // ── Opponent Model ───────────────────────────
              _buildOpponentModelSection(),
              const SizedBox(height: 8),

              // ── Expectimax ───────────────────────────────
              _buildExpectimaxSection(),
              const SizedBox(height: 8),

              // ── Cumulative Probability ───────────────────
              _buildProbabilitySection(),
              const SizedBox(height: 8),

              // ── Database ─────────────────────────────────
              ListenableBuilder(
                listenable: EvalDatabaseSettings.instance,
                builder: (context, _) => _buildDatabaseSection(),
              ),
              const SizedBox(height: 24),

              // ── Reset ────────────────────────────────────
              _buildResetButton(),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Chess Auto Prep',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  // ── Engine section ─────────────────────────────────────────────────────────

  Widget _buildEngineSection(int cores) {
    return SettingsGroup(
      title: 'Stockfish Engine',
      icon: Icons.bolt,
      children: [
        SettingsSliderTile(
          label: 'Workers (interactive)',
          tooltip: 'Parallel Stockfish processes for interactive analysis.',
          value: _engine.workers,
          min: 1,
          max: cores,
          suffix: '/ $cores cores',
          onChanged: (v) => _engine.workers = v,
        ),
        SettingsSliderTile(
          label: 'Search depth',
          tooltip: 'Search depth per position. Higher = more accurate.',
          value: _engine.depth,
          min: 1,
          max: 40,
          onChanged: (v) => _engine.depth = v,
        ),
        SettingsSliderTile(
          label: 'MultiPV',
          tooltip: 'How many top moves Stockfish evaluates in parallel.',
          value: _engine.multiPv,
          min: 1,
          max: 10,
          onChanged: (v) => _engine.multiPv = v,
        ),
        SettingsSliderTile(
          label: 'Max analysis moves',
          tooltip:
              'Maximum total moves displayed in the analysis table.',
          value: _engine.maxAnalysisMoves,
          min: 3,
          max: 20,
          onChanged: (v) => _engine.maxAnalysisMoves = v,
        ),
        SettingsSliderTile(
          label: 'Inline threads (PGN viewer)',
          tooltip:
              'Threads for the single-process inline engine bar.',
          value: _engine.inlineThreads,
          min: 1,
          max: cores,
          onChanged: (v) => _engine.inlineThreads = v,
        ),
        SettingsSliderTile(
          label: 'Maia ELO',
          tooltip:
              'Skill level of the simulated opponent for Maia predictions.',
          value: _engine.maiaElo,
          min: 600,
          max: 2400,
          divisions: 18,
          onChanged: (v) => _engine.maiaElo = v,
        ),
        SettingsSwitchTile(
          label: 'Show Stockfish analysis',
          tooltip: 'Run Stockfish in the background to evaluate moves.',
          value: _engine.showStockfish,
          onChanged: (v) => _engine.showStockfish = v,
        ),
        // Panel/column visibility toggles live on the PGN analysis settings
        // sheet only — see analysis_settings_sheet.dart.
      ],
    );
  }

  // ── Opponent model section ─────────────────────────────────────────────────

  Widget _buildOpponentModelSection() {
    final database = _engine.explorerUseMasters
        ? LichessDatabase.masters
        : LichessDatabase.lichess;
    final speeds = _engine.explorerSpeedSet;
    final ratings = _engine.explorerRatingSet;

    return SettingsGroup(
      title: 'Opponent Model',
      icon: Icons.people,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsDropdown<OpponentProbabilityMode>(
                label: 'Prediction source',
                tooltip:
                    'Maia: neural net trained on human games.\n'
                    'Lichess DB: raw move frequencies.\n'
                    'Maia + DB fallback: blends both.',
                value: _engine.opponentProbabilityMode,
                items: [
                  for (final m in OpponentProbabilityMode.values)
                    (m, m.label),
                ],
                onChanged: (v) {
                  if (v != null) _engine.opponentProbabilityMode = v;
                },
              ),
              if (_engine.fetchLichessForOpponent) ...[
                const SizedBox(height: 12),
                LichessDbSelector(
                  database: database,
                  onDatabaseChanged: (db) => _engine.explorerDatabase =
                      db == LichessDatabase.masters ? 'masters' : 'lichess',
                  selectedSpeeds: speeds,
                  onSpeedsChanged: _engine.setExplorerSpeedSet,
                  selectedRatings: ratings,
                  onRatingsChanged: _engine.setExplorerRatingSet,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Expectimax section ─────────────────────────────────────────────────────

  Widget _buildExpectimaxSection() {
    return SettingsGroup(
      title: 'Expectimax Search',
      icon: Icons.analytics,
      children: [
        SettingsSliderTile(
          label: 'On-the-fly depth',
          tooltip:
              'Search depth (plies) for positions not in the tree.',
          value: _engine.onTheFlyMaxDepth,
          min: 1,
          max: 12,
          onChanged: (v) => _engine.onTheFlyMaxDepth = v,
        ),
        SettingsSliderTile(
          label: 'Eval depth',
          tooltip: 'Stockfish depth for leaf evaluation.',
          value: _engine.expectimaxEvalDepth,
          min: 6,
          max: 20,
          onChanged: (v) => _engine.expectimaxEvalDepth = v,
        ),
        SettingsSliderTile(
          label: 'Our MultiPV',
          tooltip: 'Candidate moves for our side at each node.',
          value: _engine.expectimaxOurMultipv,
          min: 1,
          max: 8,
          onChanged: (v) => _engine.expectimaxOurMultipv = v,
        ),
        SettingsSliderTile(
          label: 'Max eval loss (cp)',
          tooltip: 'Prune opponent moves losing more than this.',
          value: _engine.expectimaxMaxEvalLoss,
          min: 20,
          max: 300,
          divisions: 28,
          onChanged: (v) => _engine.expectimaxMaxEvalLoss = v,
        ),
      ],
    );
  }

  // ── Cumulative probability section ─────────────────────────────────────────

  Widget _buildProbabilitySection() {
    return SettingsGroup(
      title: 'Cumulative Line Probability',
      icon: Icons.timeline,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SettingsTextFieldRow(
            label: 'Starting position (moves)',
            tooltip:
                'Enter opening moves (e.g. "1. e4 e5 2. Nf3") so the '
                'cumulative % starts at 100% from that position.',
            controller: _probStartCtrl,
            onSubmitted: (v) => _engine.probabilityStartMoves = v.trim(),
          ),
        ),
      ],
    );
  }

  // ── Database section ───────────────────────────────────────────────────────

  Widget _buildDatabaseSection() {
    return const SettingsGroup(
      title: 'Database',
      icon: Icons.storage,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: EvalDatabaseSettingsPanel(),
        ),
      ],
    );
  }

  // ── Reset button ───────────────────────────────────────────────────────────

  Widget _buildResetButton() {
    return Center(
      child: OutlinedButton.icon(
        icon: const Icon(Icons.restore, size: 16),
        label: const Text('Reset All to Defaults'),
        onPressed: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Reset Settings'),
              content: const Text(
                'Reset all engine, opponent, expectimax, probability, and '
                'database settings to factory defaults?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    _engine.resetToDefaults();
                    await EvalDatabaseSettings.instance.resetToDefaults();
                    _probStartCtrl.text = _engine.probabilityStartMoves;
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
