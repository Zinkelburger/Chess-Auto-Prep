/// Centralized settings screen accessible from the app bar.
///
/// Holds machine-level configuration only: engine resources and the offline
/// eval database. Analysis behavior (depth, MultiPV, expectimax tuning, panel
/// visibility) lives on the gear next to each analysis surface — see
/// analysis_settings_sheet.dart — so every knob sits where its effect is
/// visible.
///
/// Uses [ListenableBuilder] so it always reflects the latest singleton state,
/// even if another UI surface mutates [EngineSettings] concurrently.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import '../services/engine/engine_lifecycle.dart';
import '../theme/app_text_styles.dart';
import '../utils/system_info.dart';
import '../widgets/eval_database_settings_panel.dart';
import '../widgets/settings/settings_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _engine = EngineSettings.instance;

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
          // Capped column, not full width: settings rows read as
          // label-then-control pairs, and a 2000px-wide row separates the
          // two ends of that pair by the whole screen.
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Machine-level settings only. Search depth, number of '
                    'lines, expectimax tuning and panel visibility live on '
                    'the gear (⚙) next to each analysis panel, where their '
                    'effect is visible.',
                    style: AppTextStyles.caption,
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 24),

                  // ── Engine ───────────────────────────────────
                  _buildEngineSection(cores),
                  const SizedBox(height: 8),
                  const Divider(height: 24),

                  // ── Database ─────────────────────────────────
                  Builder(
                    builder: (context) {
                      context.watch<EvalDatabaseSettings>();
                      return _buildDatabaseSection();
                    },
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 24),

                  // ── Reset ────────────────────────────────────
                  _buildResetButton(),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'Chess Auto Prep',
                      style: AppTextStyles.caption.copyWith(fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Engine section ─────────────────────────────────────────────────────────

  Widget _buildEngineSection(int cores) {
    return SettingsGroup(
      title: 'Stockfish engine',
      icon: Icons.bolt,
      subtitle:
          'How much of this machine the engine may use, and which Maia '
          'opponent model predicts human replies.',
      children: [
        Builder(
          builder: (context) {
            final lifecycle = context.watch<EngineLifecycle>();
            final isOn = lifecycle.state != EngineState.off;
            final isGenerating = lifecycle.state == EngineState.generating;
            return SettingsSwitchTile(
              label: 'Enable engine analysis',
              tooltip: isGenerating
                  ? 'Engine is busy during tree generation.'
                  : 'Run Stockfish in the background for interactive analysis.',
              value: isOn,
              onChanged: (enabled) {
                if (isGenerating) return;
                if (enabled) {
                  lifecycle.toggleOn();
                } else {
                  lifecycle.toggleOff();
                }
              },
            );
          },
        ),
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
          label: 'Inline threads (PGN viewer)',
          tooltip: 'Threads for the single-process inline engine bar.',
          value: _engine.inlineThreads,
          min: 1,
          max: cores,
          onChanged: (v) => _engine.inlineThreads = v,
        ),
        SettingsSliderTile(
          label: 'Maia opponent rating',
          tooltip:
              'Skill level of the simulated opponent for Maia predictions.',
          value: _engine.maiaElo,
          min: 600,
          max: 2400,
          divisions: 18,
          onChanged: (v) => _engine.maiaElo = v,
        ),
      ],
    );
  }

  // ── Database section ───────────────────────────────────────────────────────

  Widget _buildDatabaseSection() {
    return const SettingsGroup(
      title: 'Evaluation database',
      icon: Icons.storage,
      subtitle:
          'Offline evaluation sources consulted before the engine runs, so '
          'known positions cost nothing to evaluate.',
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
                'Reset all engine, analysis, and database settings to '
                'factory defaults?',
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
