import 'package:flutter/material.dart';

import '../../../widgets/settings/settings_widgets.dart';
import '../../games/controllers/recent_games_controller.dart';
import '../../games/services/home_review_runner.dart';
import '../../games/widgets/home_review_settings_dialog.dart';
import '../controllers/tactics_session_controller.dart';
import 'tactics_session_settings_form.dart';

/// The same live session preferences and review configuration used on Home.
class TacticsViewSettings extends StatelessWidget {
  const TacticsViewSettings({
    super.key,
    required this.session,
    required this.games,
    required this.runner,
  });

  final TacticsSessionController session;
  final RecentGamesController games;
  final HomeReviewRunner runner;

  Future<void> _reviewSettings(BuildContext context) async {
    final result = await showDialog<HomeReviewSettingsResult>(
      context: context,
      builder: (_) => HomeReviewSettingsDialog(
        filters: games.filters,
        window: games.window,
      ),
    );
    if (!context.mounted || result == null) return;
    await games.setFilters(result.filters, window: result.window);
    runner.reset();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SettingsGroup(
          title: 'Session',
          icon: Icons.school_outlined,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TacticsSessionSettingsForm(
                settings: session.sessionSettings,
                showCustomType: true,
                onChanged: session.setSessionSettings,
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Game review',
          icon: Icons.analytics_outlined,
          children: [
            ListTile(
              title: const Text('Downloads and analysis'),
              subtitle: const Text(
                'Games to fetch, review depth and automatic review',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _reviewSettings(context),
            ),
          ],
        ),
      ],
    ),
  );
}
