import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../features/games/controllers/recent_games_controller.dart';
import '../../theme/app_text_styles.dart';
import '../common/home_block.dart';
import 'accounts_dialog.dart';

/// Who the app downloads games for: the Accounts block of the tactics home
/// column, in the same frame as Play, Analysis and Openings.
///
/// *Nothing set up yet* is the whole first-run problem on this screen: with no
/// username the games list is empty, the review has nothing to analyse and the
/// puzzle database stays at zero — so the block is one sentence and one
/// button that says what to do.
///
/// *Set up* is a fact, not a form: each site's name and when its games last
/// came down, with one Change button onto [AccountsDialog]. Editing is a
/// once-a-year job and does not need to sit open on a training screen.
///
/// The frame is the same in both states, so the column never jumps.
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

    if (!hasAny) {
      // Usernames are read from prefs asynchronously at startup; until that
      // finishes, "none" may just mean "still loading", so the prompt waits
      // rather than telling a configured user they have no accounts.
      return _Empty(loading: !app.usernamesLoaded);
    }
    return HomeBlock(
      heading: 'Accounts',
      trailing: HomeBlockAction(
        buttonKey: const Key('accounts-change-button'),
        label: 'Change…',
        onPressed: () => showAccountsDialog(context),
      ),
      children: [
        if (chesscom.isNotEmpty)
          _AccountRow(
            site: 'Chess.com',
            name: chesscom,
            lastFetch: app.chesscomLastFetch,
            downloading: downloading,
          ),
        if (lichess.isNotEmpty)
          _AccountRow(
            site: 'Lichess',
            name: lichess,
            lastFetch: app.lichessLastFetch,
            downloading: downloading,
          ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return HomeBlock(
      heading: 'Accounts',
      children: [
        const Text('No accounts set', style: AppTextStyles.bodyStrong),
        const SizedBox(height: 4),
        const Text(
          'Add your Lichess or Chess.com username. The app downloads those '
          'games and turns your mistakes into puzzles.',
          style: AppTextStyles.muted,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: FilledButton(
            key: const Key('accounts-setup-button'),
            onPressed: loading ? null : () => showAccountsDialog(context),
            child: Text(loading ? 'Loading…' : 'Set up my accounts'),
          ),
        ),
      ],
    );
  }
}

/// One configured account: the site as the row's label, the name as its
/// value, and under the name the one secondary fact — when that site's games
/// last came down. Two lines, so the date can say what it is instead of
/// being a bare "Sep 4, 2026" squeezed after the name.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.site,
    required this.name,
    required this.lastFetch,
    required this.downloading,
  });

  final String site;
  final String name;
  final DateTime? lastFetch;

  /// A load is in flight right now, so the date is about to change. Saying so
  /// beats reporting a date the left pane is contradicting with a progress
  /// bar.
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    final status = downloading
        ? 'Downloading…'
        : lastFetch != null
        ? 'Downloaded ${formatAccountDate(lastFetch!)}'
        : 'Not downloaded yet';
    return HomeBlockRow(
      label: site,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodyStrong,
          ),
          Text(status, style: AppTextStyles.muted),
        ],
      ),
    );
  }
}
