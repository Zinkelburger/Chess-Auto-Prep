/// Master-games database (The Week in Chess) settings: what is downloaded,
/// how far back, and whether the generator uses it.
///
/// Mounted from [SettingsScreen]; the same [MasterGamesService] drives the
/// first-run prompt on the repertoire screen and the Jobs-pane progress.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../features/master_games/widgets/master_games_browser.dart';
import '../services/master_games/master_games_service.dart';
import '../services/master_games/twic_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'settings/settings_widgets.dart';

class MasterGamesSettingsPanel extends StatelessWidget {
  const MasterGamesSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<MasterGamesService>();
    final stats = service.stats;
    final yearsBack = _yearsBack(service.startIssue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            stats == null || stats.isEmpty
                ? 'No master games downloaded yet.'
                : '${_thousands(stats.games)} games from TWIC issues '
                      '${stats.firstIssue}–${stats.lastIssue} '
                      '(${stats.issues} issues, '
                      '${(stats.fileBytes / 1e9).toStringAsFixed(1)} GB).',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        SettingsStepperTile(
          label: 'Years of games',
          description:
              'How far back the download reaches. TWIC has weekly PGN '
              'issues since September 2012; more years means more disk '
              '(roughly 0.6 GB per year) and a longer first download.',
          value: yearsBack,
          min: 1,
          max: _maxYears(),
          suffix: 'years',
          onChanged: service.isSyncing
              ? (_) {}
              : (v) => service.setStartIssue(twicIssueYearsBack(v)),
        ),
        SettingsSwitchTile(
          label: 'Check for new issues at startup',
          tooltip:
              'TWIC publishes every Monday. Once the database exists, a new '
              'issue is fetched automatically when the app starts (at most '
              'once a day).',
          value: service.autoSync,
          onChanged: service.setAutoSync,
        ),
        SettingsSwitchTile(
          label: 'Use master games when generating',
          tooltip:
              'Opponent replies from titled-player practice, real model '
              'games, and "improves on … in <game>" notes where the '
              'repertoire beats what masters played.',
          value: service.useInGeneration,
          onChanged: service.setUseInGeneration,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: service.isSyncing ? null : () => service.sync(),
                icon: const Icon(Icons.cloud_download_outlined, size: 16),
                label: Text(
                  stats == null || stats.isEmpty
                      ? 'Download master games'
                      : 'Check for new issues',
                ),
              ),
              const SizedBox(width: 8),
              if (service.isSyncing)
                OutlinedButton(
                  onPressed: service.cancel,
                  child: const Text('Stop'),
                ),
              if (stats != null && !stats.isEmpty) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => showMasterGamesBrowser(
                    context,
                    appState: context.read<AppState>(),
                  ),
                  icon: const Icon(Icons.travel_explore, size: 16),
                  label: const Text('Browse games…'),
                ),
              ],
              const Spacer(),
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://theweekinchess.com/twic'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('theweekinchess.com'),
              ),
            ],
          ),
        ),
        if (service.isSyncing || service.status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (service.isSyncing)
                  LinearProgressIndicator(
                    value: service.fraction > 0 ? service.fraction : null,
                  ),
                const SizedBox(height: 4),
                Text(
                  service.status,
                  style: TextStyle(
                    fontSize: 12,
                    color: service.lastError != null
                        ? AppColors.danger
                        : AppColors.onSurfaceMuted,
                  ),
                ),
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Games are © The Week in Chess (Mark Crowther) and free for '
            'personal use. Downloads run in the background — see the Jobs '
            'pane — and stopping keeps every issue already imported.',
            style: AppTextStyles.caption,
          ),
        ),
      ],
    );
  }

  static int _yearsBack(int startIssue) {
    final now = twicIssueEstimateFor(DateTime.now());
    final years = ((now - startIssue) / 52).round();
    return years < 1 ? 1 : years;
  }

  static int _maxYears() {
    final now = twicIssueEstimateFor(DateTime.now());
    return ((now - kTwicFirstPgnIssue) / 52).ceil();
  }

  static String _thousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}
