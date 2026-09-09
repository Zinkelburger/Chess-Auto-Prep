/// Shared analysis preferences, reachable from the app settings sidebar.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_state.dart';
import '../../constants/engine_defaults.dart';

import '../../models/engine_settings.dart';
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
    final settings = EngineSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            SettingsSwitchRow(
              label: 'Stockfish evals in move table',
              value: settings.showStockfish,
              onChanged: (v) => settings.showStockfish = v,
            ),
            SettingsStepperTile(
              label: 'Max table moves',
              value: settings.maxAnalysisMoves,
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
