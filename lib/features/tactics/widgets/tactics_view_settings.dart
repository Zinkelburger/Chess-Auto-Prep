import 'package:flutter/material.dart';

import '../../../widgets/settings/settings_navigation.dart';
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
    final chapter = SettingsChapterScope.maybeOf(context) ?? 0;
    if (chapter >= 2) {
      return HomeReviewSettingsDialog(
        filters: games.filters,
        window: games.window,
        embedded: true,
        onApply: (result) async {
          await games.setFilters(result.filters, window: result.window);
          runner.reset();
        },
      );
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => ListView(
        key: ValueKey(chapter),
        padding: const EdgeInsets.all(24),
        children: [
          TacticsSessionSettingsForm(
            settings: session.sessionSettings,
            showCustomType: true,
            section: chapter == 0
                ? TacticsSettingsSection.session
                : TacticsSettingsSection.selection,
            onChanged: session.setSessionSettings,
          ),
        ],
      ),
    );
  }
}
