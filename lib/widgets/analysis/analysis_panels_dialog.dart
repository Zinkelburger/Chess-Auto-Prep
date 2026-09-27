/// Shared analysis preferences, reachable from the app settings sidebar.
library;

import '../../features/settings/widgets/settings_section_status.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_state.dart';
import '../../constants/engine_defaults.dart';

import '../../features/settings/controllers/engine_settings.dart';
import '../settings/settings_widgets.dart';
import '../app_settings_button.dart';

/// Opens the analysis-panels visibility dialog.
Future<void> showAnalysisPanelsDialog(BuildContext context) => openAppSettings(
  context,
  initialMode: context.read<AppState>().currentMode,
  initialChapter: switch (context.read<AppState>().currentMode) {
    AppMode.repertoire => 1,
    AppMode.pgnViewer => 2,
    _ => 0,
  },
);

class AnalysisPanelsSettingsBody extends StatelessWidget {
  const AnalysisPanelsSettingsBody({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<EngineSettings>();
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSectionStatus(
              owner: settings,
              policy:
                  'Display changes apply after saving. Search changes apply to the next position.',
            ),
            SettingsSwitchRow(
              label: 'Engine continuations',
              tooltip:
                  'Show the Stockfish principal variation panel — top engine '
                  'moves, eval, and continuation for the current board '
                  'position.',
              value: settings.editing.showEngineDock,
              onChanged: (v) => settings.showEngineDock = v,
            ),
            SettingsSwitchRow(
              label: 'Practical move scores (Expectimax)',
              tooltip:
                  'Show the Expectimax panel — every move at the current '
                  'position with the practical value the build stored for '
                  'it. Read from the built tree; does not run the engine.',
              value: settings.editing.showExpectimaxDock,
              onChanged: (v) => settings.showExpectimaxDock = v,
            ),
            SettingsSwitchRow(
              label: 'Predicted move frequency (Maia)',
              tooltip: 'Show the Maia prediction column in the move table.',
              value: settings.editing.showMaia,
              onChanged: (v) => settings.showMaia = v,
            ),
            SettingsSwitchRow(
              label: 'Engine scores in move table',
              value: settings.editing.showStockfish,
              onChanged: (v) => settings.showStockfish = v,
            ),
            SettingsStepperTile(
              label: 'Moves shown',
              value: settings.editing.maxAnalysisMoves,
              min: kMinMaxAnalysisMoves,
              max: kMaxMaxAnalysisMoves,
              onChanged: (v) => settings.maxAnalysisMoves = v,
            ),
          ],
        ),
      ),
    );
  }
}
