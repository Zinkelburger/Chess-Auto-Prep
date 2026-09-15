import 'package:flutter/material.dart';

import '../../games/controllers/recent_games_controller.dart';
import '../../games/services/home_review_runner.dart';
import '../../games/widgets/home_review_settings_dialog.dart';
import '../controllers/tactics_session_controller.dart';
import 'tactics_session_settings_form.dart';

/// Focused chapters over the live tactics session and game review settings.
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TacticsSessionSettingsForm(
            settings: session.sessionSettings,
            showCustomType: true,
            onChanged: session.setSessionSettings,
          ),
          ...[
            const Divider(height: 32),
            const Text('Game downloads'),
            HomeReviewSettingsDialog(
              filters: games.filters,
              window: games.window,
              embedded: true,
              onApply: (result) async {
                await games.setFilters(result.filters, window: result.window);
                runner.reset();
              },
            ),
          ],
        ],
      ),
    );
  }
}
