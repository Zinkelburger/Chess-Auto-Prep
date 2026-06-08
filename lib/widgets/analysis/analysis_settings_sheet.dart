/// Analysis settings dialog — context-aware.
///
/// Shows different sections depending on [AnalysisSettingsContext]:
/// - [AnalysisSettingsContext.full]: panel visibility, Lichess DB filters,
///   engine depth/multiPv, and a link to the global settings screen.
/// - [AnalysisSettingsContext.tacticsEngine]: engine depth and multiPv only.
library;

import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/engine_settings.dart';
import '../../screens/settings_screen.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../lichess_db_selector.dart';
import '../settings/settings_widgets.dart';

/// Which surface opened the sheet — controls which sections are shown.
enum AnalysisSettingsContext {
  /// Full analysis (PGN editor, repertoire dock): all sections.
  full,

  /// Tactics inline engine: depth and number of variations only.
  tacticsEngine,
}

/// Opens a dialog with analysis settings scoped to [mode].
Future<void> showAnalysisSettingsSheet(
  BuildContext context, {
  AnalysisSettingsContext mode = AnalysisSettingsContext.full,
}) async {
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return;

  final size = MediaQuery.sizeOf(context);
  final width = (size.width - 32).clamp(320.0, 560.0);
  final height = (size.height - 32).clamp(320.0, 520.0);

  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: width,
        height: height,
        child: _AnalysisSettingsSheet(mode: mode),
      ),
    ),
  );
}

class _AnalysisSettingsSheet extends StatefulWidget {
  final AnalysisSettingsContext mode;
  const _AnalysisSettingsSheet({required this.mode});

  @override
  State<_AnalysisSettingsSheet> createState() => _AnalysisSettingsSheetState();
}

class _AnalysisSettingsSheetState extends State<_AnalysisSettingsSheet> {
  final _settings = EngineSettings();

  bool get _isFull => widget.mode == AnalysisSettingsContext.full;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          children: [
            _buildTitleBar(theme),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildEngineSection(),
                    if (_isFull) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 16),
                      _buildPanelsSection(),
                    ],
                    if (_isFull &&
                        _settings.fetchLichessForOpponent) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 16),
                      _buildLichessDbFiltersSection(),
                    ],
                    if (_isFull) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 12),
                      _buildOpenSettingsLink(context),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar(ThemeData theme) {
    final title = _isFull ? 'Analysis settings' : 'Engine settings';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
      child: Row(
        children: [
          Icon(Icons.tune, color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 10),
          Text(
            title,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // ── Engine depth & multiPv (shown in all contexts) ─────────────────────────

  Widget _buildEngineSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SettingsSection(
        icon: Icons.memory,
        title: 'Engine',
        showDivider: false,
        child: SettingsIntGrid(
          fields: [
            SettingsIntSpec(
              label: 'Depth',
              tooltip: 'Stockfish search depth per position.',
              value: _settings.depth,
              min: kMinDepth,
              max: kMaxDepth,
              onChanged: (v) => _settings.depth = v,
            ),
            SettingsIntSpec(
              label: 'Lines (MultiPV)',
              tooltip: 'Number of top variations to evaluate.',
              value: _settings.multiPv,
              min: kMinMultiPv,
              max: kMaxMultiPv,
              onChanged: (v) => _settings.multiPv = v,
            ),
          ],
        ),
      ),
    );
  }

  // ── Panel visibility (owned here; not duplicated on SettingsScreen) ───────

  Widget _buildPanelsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SettingsSection(
        icon: Icons.view_column,
        title: 'Analysis panels',
        subtitle: 'Live analysis shown above the PGN notation. '
            'You can also tap a column header in the move table '
            'to dim it without hiding it.',
        showDivider: false,
        child: Column(
          children: [
            SettingsSwitchRow(
              label: 'Stockfish PV',
              tooltip:
                  'Show the Stockfish principal variation panel — '
                  'top engine moves, eval, and continuation for the '
                  'current board position.',
              value: _settings.showEngineDock,
              onChanged: (v) => _settings.showEngineDock = v,
            ),
            SettingsSwitchRow(
              label: 'Expectimax PV',
              tooltip:
                  'Show the Expectimax panel — best practical lines '
                  'that account for likely human opponent replies.',
              value: _settings.showExpectimaxDock,
              onChanged: (v) => _settings.showExpectimaxDock = v,
            ),
            SettingsSwitchRow(
              label: 'Show Maia % column',
              tooltip: 'Show the Maia prediction column in the move table.',
              value: _settings.showMaia,
              onChanged: (v) => _settings.showMaia = v,
            ),
            SettingsSwitchRow(
              label: 'Show DB % column',
              tooltip: 'Show the Lichess database frequency column.',
              value: _settings.showProbability,
              onChanged: (v) => _settings.showProbability = v,
            ),
          ],
        ),
      ),
    );
  }

  // ── Contextual Lichess DB filters (mode is on SettingsScreen) ─────────────

  Widget _buildLichessDbFiltersSection() {
    final database = _settings.explorerUseMasters
        ? LichessDatabase.masters
        : LichessDatabase.lichess;
    final speeds = _settings.explorerSpeedSet;
    final ratings = _settings.explorerRatingSet;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SettingsSection(
        icon: Icons.filter_list,
        title: 'Lichess database filters',
        subtitle:
            'Speed and rating filters for the current opponent model. '
            'Change the prediction source in Settings → Opponent Model.',
        showDivider: false,
        child: LichessDbSelector(
          database: database,
          onDatabaseChanged: (db) => _settings.explorerDatabase =
              db == LichessDatabase.masters ? 'masters' : 'lichess',
          selectedSpeeds: speeds,
          onSpeedsChanged: _settings.setExplorerSpeedSet,
          selectedRatings: ratings,
          onRatingsChanged: _settings.setExplorerRatingSet,
        ),
      ),
    );
  }

  Widget _buildOpenSettingsLink(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        icon: const Icon(Icons.settings_outlined, size: 18),
        label: const Text('Open Settings for engine, opponent, and database'),
        onPressed: () {
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const SettingsScreen(),
            ),
          );
        },
      ),
    );
  }
}
