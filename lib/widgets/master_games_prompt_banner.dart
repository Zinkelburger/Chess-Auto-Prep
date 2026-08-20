/// First-run nudge on the repertoire screen: the generator is better with a
/// master-games base, and the download is one click.  Shown until the user
/// downloads or dismisses; while a download runs it shows progress instead.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/master_games/master_games_service.dart';
import '../theme/app_colors.dart';

class MasterGamesPromptBanner extends StatelessWidget {
  const MasterGamesPromptBanner({super.key, this.onShowJobs});

  /// Opens the Jobs pane where the download's progress lives.
  final VoidCallback? onShowJobs;

  /// Whether the banner has anything to say for [service]'s current state.
  static bool isRelevant(MasterGamesService service) =>
      service.isLoaded &&
      (service.isSyncing || (!service.hasGames && !service.promptDismissed));

  @override
  Widget build(BuildContext context) {
    // Nullable watch: screens hosted without the app-level providers (widget
    // tests, previews) simply show no banner.
    final service = context.watch<MasterGamesService?>();
    if (service == null || !isRelevant(service)) {
      return const SizedBox.shrink();
    }

    final syncing = service.isSyncing;
    return Material(
      color: AppColors.accent.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(
              Icons.library_books_outlined,
              size: 16,
              color: AppColors.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                syncing
                    ? 'Downloading master games — ${service.status}'
                    : 'Build repertoires on master games: download '
                          'The Week in Chess (last $kMasterGamesDefaultYears '
                          'years, ~3 GB) once and the generator uses '
                          'titled-player practice, real model games and '
                          '"improves on … in <game>" notes.',
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            if (syncing) ...[
              if (onShowJobs != null)
                TextButton(onPressed: onShowJobs, child: const Text('Jobs')),
              TextButton(onPressed: service.cancel, child: const Text('Stop')),
            ] else ...[
              TextButton(
                onPressed: () {
                  service.sync();
                  onShowJobs?.call();
                },
                child: const Text('Download'),
              ),
              TextButton(
                onPressed: service.dismissPrompt,
                child: const Text('Not now'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
