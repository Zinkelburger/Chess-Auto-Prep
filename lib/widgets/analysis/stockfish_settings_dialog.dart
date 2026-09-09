/// Shared analysis preferences, reachable from the app settings sidebar.
library;

import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_colors.dart';
import '../settings/settings_widgets.dart';
import '../app_settings_button.dart';

/// Opens the Stockfish settings dialog.
Future<void> showStockfishSettingsDialog(BuildContext context) =>
    openAppSettings(context, initialGlobalSection: 7);

class StockfishSettingsBody extends StatelessWidget {
  const StockfishSettingsBody({super.key});

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
            SettingsSection(
              icon: Icons.search,
              title: 'Search',
              child: SettingsIntGrid(
                fields: [
                  SettingsIntSpec(
                    label: 'Depth',
                    tooltip: 'Stockfish search depth per position.',
                    value: settings.depth,
                    min: kMinDepth,
                    max: kMaxDepth,
                    onChanged: (v) => settings.depth = v,
                  ),
                  SettingsIntSpec(
                    label: 'Lines (MultiPV)',
                    tooltip: 'Number of top variations to evaluate.',
                    value: settings.multiPv,
                    min: kMinMultiPv,
                    max: kMaxMultiPv,
                    onChanged: (v) => settings.multiPv = v,
                  ),
                  SettingsIntSpec(
                    label: 'PV rows per line',
                    tooltip:
                        'Text rows each engine line gives its continuation. 2 '
                        'or more lets a long variation wrap instead of being '
                        'cut off at the edge of the panel.',
                    value: settings.pvRows,
                    min: kMinPvRows,
                    max: kMaxPvRows,
                    onChanged: (v) => settings.pvRows = v,
                  ),
                ],
              ),
            ),
            SettingsSection(
              icon: Icons.table_chart_outlined,
              title: 'Move table',
              showDivider: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsSwitchRow(
                    label: 'Stockfish evals in move table',
                    tooltip:
                        'Run Stockfish to evaluate candidate moves in the '
                        'move table. Turn off to rely on Maia/database only.',
                    value: settings.showStockfish,
                    onChanged: (v) => settings.showStockfish = v,
                  ),
                  SettingsIntGrid(
                    fields: [
                      SettingsIntSpec(
                        label: 'Max table moves',
                        tooltip:
                            'Maximum total moves displayed in the analysis '
                            'table.',
                        value: settings.maxAnalysisMoves,
                        min: kMinMaxAnalysisMoves,
                        max: kMaxMaxAnalysisMoves,
                        onChanged: (v) => settings.maxAnalysisMoves = v,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'CPU cores, memory and the opponent rating are in '
              'Global settings → Engine.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
