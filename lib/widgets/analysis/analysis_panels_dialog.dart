/// Analysis panels — which live-analysis surfaces are shown.
///
/// Visibility toggles only: each panel's own knobs live behind its own gear
/// (stockfish_settings_dialog.dart, expectimax_settings_dialog.dart) —
/// deliberately three separate dialogs, not modes of one.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/engine/engine_lifecycle.dart';
import '../../theme/app_colors.dart';
import '../settings/settings_widgets.dart';

/// Opens the analysis-panels visibility dialog.
Future<void> showAnalysisPanelsDialog(BuildContext context) {
  return showSettingsDialog(
    context,
    icon: Icons.view_column,
    title: 'Analysis panels',
    bodyBuilder: (_) => const _AnalysisPanelsBody(),
  );
}

class _AnalysisPanelsBody extends StatelessWidget {
  const _AnalysisPanelsBody();

  @override
  Widget build(BuildContext context) {
    final settings = EngineSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Live analysis shown above the PGN notation. Each panel\'s own '
              'settings are behind the gear (⚙) in that panel. You can also '
              'tap a column header in the move table to dim it without '
              'hiding it.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            SettingsSwitchRow(
              label: 'Stockfish PV',
              tooltip:
                  'Show the Stockfish principal variation panel — top engine '
                  'moves, eval, and continuation for the current board '
                  'position.',
              value: settings.showEngineDock,
              onChanged: (v) => settings.showEngineDock = v,
            ),
            SettingsSwitchRow(
              label: 'Expectimax PV',
              tooltip:
                  'Show the Expectimax panel — best practical lines that '
                  'account for likely human opponent replies.',
              value: settings.showExpectimaxDock,
              onChanged: (v) {
                settings.showExpectimaxDock = v;
                // Explicitly enabling expectimax overrides the persisted
                // engine kill switch — compute can't run without Stockfish.
                if (v && EngineLifecycle.instance.state == EngineState.off) {
                  unawaited(EngineLifecycle.instance.toggleOn());
                }
              },
            ),
            SettingsSwitchRow(
              label: 'Show Maia % column',
              tooltip: 'Show the Maia prediction column in the move table.',
              value: settings.showMaia,
              onChanged: (v) => settings.showMaia = v,
            ),
            // Mothballed: Lichess Explorer DB column hidden.
            // SettingsSwitchRow(
            //   label: 'Show DB % column',
            //   value: settings.showProbability,
            //   onChanged: (v) => settings.showProbability = v,
            // ),
          ],
        ),
      ),
    );
  }
}
