/// On-the-fly expectimax settings — the dialog behind the expectimax gear.
///
/// Controls the live expectimax pane only; the Generate form's tree search
/// has its own settings on that form. Its siblings are
/// stockfish_settings_dialog.dart and analysis_panels_dialog.dart —
/// deliberately three separate dialogs, not modes of one.
library;

import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_colors.dart';
import '../settings/settings_widgets.dart';

/// Opens the on-the-fly expectimax settings dialog.
Future<void> showExpectimaxSettingsDialog(BuildContext context) {
  return showSettingsDialog(
    context,
    icon: Icons.auto_graph,
    title: 'On-the-fly expectimax settings',
    bodyBuilder: (_) => const _ExpectimaxSettingsBody(),
  );
}

class _ExpectimaxSettingsBody extends StatelessWidget {
  const _ExpectimaxSettingsBody();

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
              'Applies to the live expectimax pane only. The Generate form '
              'has its own search settings.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 14),
            SettingsSection(
              icon: Icons.search,
              title: 'Search',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsIntGrid(
                    fields: [
                      SettingsIntSpec(
                        label: 'Lookahead depth',
                        tooltip:
                            'Max ply depth for on-the-fly expectimax '
                            'computation.',
                        value: settings.onTheFlyMaxDepth,
                        min: 1,
                        max: 10,
                        onChanged: (v) => settings.onTheFlyMaxDepth = v,
                      ),
                      SettingsIntSpec(
                        label: 'Our lines (MultiPV)',
                        tooltip:
                            'Number of top candidate moves to explore for '
                            'your side.',
                        value: settings.expectimaxOurMultipv,
                        min: kMinExpOurMultipv,
                        max: kMaxExpOurMultipv,
                        onChanged: (v) => settings.expectimaxOurMultipv = v,
                      ),
                      SettingsIntSpec(
                        label: 'Eval depth',
                        tooltip:
                            'Stockfish depth for evaluating expectimax '
                            'positions.',
                        value: settings.expectimaxEvalDepth,
                        min: kMinExpEvalDepth,
                        max: kMaxExpEvalDepth,
                        onChanged: (v) => settings.expectimaxEvalDepth = v,
                      ),
                      SettingsIntSpec(
                        label: 'Max eval loss (cp)',
                        tooltip:
                            'Maximum centipawn loss to consider a move '
                            'viable.',
                        value: settings.expectimaxMaxEvalLoss,
                        min: kMinExpMaxEvalLoss,
                        max: kMaxExpMaxEvalLoss,
                        onChanged: (v) => settings.expectimaxMaxEvalLoss = v,
                      ),
                    ],
                  ),
                  SettingsSwitchRow(
                    label: 'Fast search',
                    tooltip:
                        'Same choice as the Generate form: Fast explores '
                        'the likeliest opponent lines first and prunes '
                        'unlikely branches harder, so the position budget '
                        'goes where games actually go. Turn off for Pure '
                        'search — every position at full width, but slower '
                        'to reach useful depth.',
                    value: settings.expectimaxFastSearch,
                    onChanged: (v) => settings.expectimaxFastSearch = v,
                  ),
                ],
              ),
            ),
            SettingsSection(
              icon: Icons.people_outline,
              title: 'Opponent replies',
              subtitle: 'Which opponent moves the search bothers to answer.',
              showDivider: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsIntGrid(
                    fields: [
                      SettingsIntSpec(
                        label: 'Replies per position',
                        tooltip:
                            'Most opponent replies explored at each '
                            'position.',
                        value: settings.expectimaxOppMaxChildren,
                        min: kMinExpOppMaxChildren,
                        max: kMaxExpOppMaxChildren,
                        onChanged: (v) => settings.expectimaxOppMaxChildren = v,
                      ),
                    ],
                  ),
                  SettingsSliderTile(
                    label: 'Reply coverage target',
                    tooltip:
                        'Keep adding opponent replies until this share of '
                        'their likely moves is covered.',
                    value: (settings.expectimaxOppMassTarget * 100).round(),
                    min: (kMinExpOppMassTarget * 100).round(),
                    max: (kMaxExpOppMassTarget * 100).round(),
                    suffix: '%',
                    onChanged: (v) =>
                        settings.expectimaxOppMassTarget = v / 100,
                  ),
                  SettingsSliderTile(
                    label: 'Ignore replies below',
                    tooltip:
                        'Opponent replies with less than this chance of '
                        'being played are skipped.',
                    value: (settings.expectimaxMinProb * 100).round().clamp(
                      1,
                      (kMaxExpMinProb * 100).round(),
                    ),
                    min: 1,
                    max: (kMaxExpMinProb * 100).round(),
                    suffix: '%',
                    onChanged: (v) => settings.expectimaxMinProb = v / 100,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
