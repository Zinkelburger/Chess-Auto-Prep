/// Analysis panels — which live-analysis surfaces are shown.
///
/// Visibility toggles only: the engine panel's own knobs live behind its
/// gear (stockfish_settings_dialog.dart) — deliberately a separate dialog,
/// not a mode of this one.  The expectimax panel has no knobs: it shows what
/// the build stored.
library;

import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
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
              label: 'Expectimax',
              tooltip:
                  'Show the Expectimax panel — every move at the current '
                  'position with the practical value the build stored for '
                  'it. Read from the built tree; does not run the engine.',
              value: settings.showExpectimaxDock,
              onChanged: (v) => settings.showExpectimaxDock = v,
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
