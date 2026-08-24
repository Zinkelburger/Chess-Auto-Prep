import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../features/games/controllers/recent_games_controller.dart';
import '../../theme/app_colors.dart';
import 'accounts_dialog.dart';

/// Who the app downloads games for, as one card with two states.
///
/// *Nothing set up yet* is the whole first-run problem on this screen: with no
/// username the games list is empty, the review has nothing to analyse and the
/// puzzle database stays at zero — so the card is a single button that says
/// what to do, not a pair of unlabelled boxes you have to recognise as the
/// starting point.
///
/// *Set up* is a fact, not a form: the names and when each was last downloaded,
/// with one Change button onto [AccountsDialog]. Editing is a once-a-year job
/// and does not need to sit open on a training screen.
class AccountsCard extends StatelessWidget {
  const AccountsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final lichess = app.lichessUsername?.trim() ?? '';
    final chesscom = app.chesscomUsername?.trim() ?? '';
    final hasAny = lichess.isNotEmpty || chesscom.isNotEmpty;
    // The games loader, when this card is on the tactics home. Read nullably
    // so the card still works anywhere it is not (Settings, tests).
    final downloading =
        context.watch<RecentGamesController?>()?.isLoading ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: hasAny
              ? _Configured(
                  lichess: lichess,
                  chesscom: chesscom,
                  lichessFetch: app.lichessLastFetch,
                  chesscomFetch: app.chesscomLastFetch,
                  downloading: downloading,
                )
              // Usernames are read from prefs asynchronously at startup; until
              // that finishes, "none" may just mean "still loading", so the
              // prompt waits rather than telling a configured user they have
              // no accounts. Same shape either way — the card never jumps.
              : _Empty(loading: !app.usernamesLoaded),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(
              Icons.person_off_outlined,
              size: 18,
              color: AppColors.onSurfaceMuted,
            ),
            SizedBox(width: 8),
            Text(
              'No accounts set',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Tell the app your Lichess or Chess.com username and it can '
          'download your games, find your mistakes and turn them into '
          'puzzles.',
          style: TextStyle(fontSize: 12.5, color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 44,
          child: FilledButton.icon(
            key: const Key('accounts-setup-button'),
            onPressed: loading ? null : () => showAccountsDialog(context),
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: Text(loading ? 'Loading…' : 'Set up my accounts'),
          ),
        ),
      ],
    );
  }
}

class _Configured extends StatelessWidget {
  const _Configured({
    required this.lichess,
    required this.chesscom,
    required this.lichessFetch,
    required this.chesscomFetch,
    required this.downloading,
  });

  final String lichess;
  final String chesscom;
  final DateTime? lichessFetch;
  final DateTime? chesscomFetch;

  /// A load is in flight right now, so the date beside every name is about to
  /// change. Saying so beats reporting a date the left pane is contradicting
  /// with a progress bar.
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'My accounts',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              key: const Key('accounts-change-button'),
              onPressed: () => showAccountsDialog(context),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Change'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (lichess.isNotEmpty)
          _AccountLine(
            site: 'Lichess',
            name: lichess,
            lastFetch: lichessFetch,
            downloading: downloading,
          ),
        if (chesscom.isNotEmpty)
          _AccountLine(
            site: 'Chess.com',
            name: chesscom,
            lastFetch: chesscomFetch,
            downloading: downloading,
          ),
      ],
    );
  }
}

/// One configured account: site, name, and when its games last came down.
class _AccountLine extends StatelessWidget {
  const _AccountLine({
    required this.site,
    required this.name,
    required this.lastFetch,
    required this.downloading,
  });

  final String site;
  final String name;
  final DateTime? lastFetch;
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(
              site,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            downloading
                ? 'Downloading…'
                : lastFetch != null
                ? formatAccountDate(lastFetch!)
                : 'Not downloaded yet',
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
      ),
    );
  }
}
