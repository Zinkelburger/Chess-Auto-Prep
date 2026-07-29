/// Stockfish settings — the dialog behind every Stockfish gear (⚙).
///
/// One stable dialog wherever Stockfish analysis appears: the inline engine
/// bar, the unified engine pane, and the analysis dock. Its siblings are
/// expectimax_settings_dialog.dart (the on-the-fly expectimax pane) and
/// analysis_panels_dialog.dart (panel visibility) — deliberately three
/// separate dialogs, not modes of one.
library;

import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_colors.dart';
import '../settings/settings_widgets.dart';

/// Opens the Stockfish settings dialog.
Future<void> showStockfishSettingsDialog(BuildContext context) {
  return showSettingsDialog(
    context,
    icon: Icons.memory,
    title: 'Stockfish settings',
    bodyBuilder: (_) => const _StockfishSettingsBody(),
  );
}

class _StockfishSettingsBody extends StatelessWidget {
  const _StockfishSettingsBody();

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
              subtitle: 'The candidate-move table in analysis views.',
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
              'Machine-level knobs — engine workers, inline threads, and the '
              'Maia rating — live in App settings (⚙ in the top bar).',
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
