/// The settings half of the master-games database: how far back to download,
/// whether to keep it current, and whether the generator uses it.
///
/// Mounted by the Databases page inside a database card's disclosure. The card
/// owns the *status* half — the count, the size, when it was last checked, and
/// the download button — because those are the three things every store on
/// that page answers in the same place, and a panel that answered them its own
/// way was a panel a reader could not compare with the one below it.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/master_games/master_games_service.dart';
import '../services/master_games/twic_client.dart';
import '../theme/app_text_styles.dart';
import 'settings/settings_widgets.dart';

class MasterGamesSettingsPanel extends StatelessWidget {
  const MasterGamesSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<MasterGamesService>();
    final yearsBack = _yearsBack(service.startIssue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const Padding(
          padding: EdgeInsets.only(top: 8),
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
}
