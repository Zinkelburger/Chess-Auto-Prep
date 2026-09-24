import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/tactics/game_ids.dart';
import '../../storage/my_accounts.dart';
import '../../ui/theme.dart';
import 'my_games.dart';
import 'my_games_words.dart';

/// The top of the Tactics column: whose games these are, the one button
/// that fetches and reviews them, and one line saying where that stands.
/// With no username yet it is only the way to add one.
class MyGamesBlock extends StatelessWidget {
  const MyGamesBlock({super.key, required this.games});

  final MyGames games;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: games,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (games.accountProblem case final problem?) ...[
              Text(
                problem,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              TextButton(
                onPressed: games.savingAccounts
                    ? null
                    : () => unawaited(games.retryUsernames()),
                child: const Text('Retry save'),
              ),
            ],
            games.accounts.isEmpty ? _setUp(context) : _ready(context),
          ],
        ),
      ),
    );
  }

  Widget _setUp(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Add your Lichess or Chess.com username to turn your mistakes into '
        'puzzles.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: Space.s),
      FilledButton(
        onPressed: games.savingAccounts
            ? null
            : () => unawaited(editAccounts(context, games)),
        child: const Text('Add accounts'),
      ),
      const SizedBox(height: Space.s),
      const Divider(height: 1),
    ],
  );

  Widget _ready(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = myGamesLine(games.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Usernames(games: games),
        _Transport(games: games),
        if (line.isNotEmpty) ...[
          const SizedBox(height: Space.xs),
          Text(
            line,
            style: switch (games.status) {
              MyGamesFailed() ||
              MyGamesNotDownloaded() => text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
              _ => text.bodySmall,
            },
          ),
        ],
        const SizedBox(height: Space.s),
        const Divider(height: 1),
      ],
    );
  }
}

/// Each username on its own line, and the way to change them.
class _Usernames extends StatelessWidget {
  const _Usernames({required this.games});

  final MyGames games;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final MapEntry(key: site, value: account)
                  in games.accounts.entries)
                Tooltip(
                  message: '${site.label} username',
                  child: Text(
                    account.username,
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        TextButton(
          onPressed: games.running || games.savingAccounts
              ? null
              : () => unawaited(editAccounts(context, games)),
          child: const Text('Change'),
        ),
      ],
    );
  }
}

/// Get games, Pause while it runs, Resume after a pause.
class _Transport extends StatelessWidget {
  const _Transport({required this.games});

  final MyGames games;

  @override
  Widget build(BuildContext context) {
    final pausing = switch (games.status) {
      MyGamesDownloading(:final pausing) => pausing,
      MyGamesReviewing(:final pausing) => pausing,
      _ => false,
    };
    final (label, icon, tip) = games.running
        ? (
            'Pause',
            Icons.pause,
            'Stop after the game being looked at; press again to carry on',
          )
        : games.queued > 0
        ? (
            'Resume',
            Icons.play_arrow,
            'Carry on with the ${games.queued} games still to look at',
          )
        : (
            'Get games',
            Icons.download,
            'Download your new games on each account and turn your '
                'mistakes in the newest $reviewWindow into puzzles',
          );
    return Tooltip(
      message: tip,
      child: FilledButton.icon(
        onPressed: pausing
            ? null
            : games.running
            ? games.pause
            : games.accountsUnsettled
            ? null
            : () => unawaited(games.start()),
        icon: Icon(icon, size: IconSize.action),
        label: Text(label),
      ),
    );
  }
}

/// Opens the usernames and keeps what was typed. Nothing downloads.
Future<void> editAccounts(BuildContext context, MyGames games) async {
  final chosen = await showAccountsDialog(context, accounts: games.accounts);
  if (chosen == null) return;
  await games.saveUsernames(lichess: chosen.lichess, chesscom: chosen.chesscom);
}

/// The two usernames, typed in: no password, no login. Answers the pair to
/// keep, blank for none, or null when the user backed out. Nothing is
/// downloaded from here.
Future<({String lichess, String chesscom})?> showAccountsDialog(
  BuildContext context, {
  required Map<GameSite, Account> accounts,
}) => showDialog(
  context: context,
  builder: (context) => _AccountsDialog(accounts: accounts),
);

class _AccountsDialog extends StatefulWidget {
  const _AccountsDialog({required this.accounts});

  final Map<GameSite, Account> accounts;

  @override
  State<_AccountsDialog> createState() => _AccountsDialogState();
}

class _AccountsDialogState extends State<_AccountsDialog> {
  late final _lichess = TextEditingController(
    text: widget.accounts[GameSite.lichess]?.username ?? '',
  );
  late final _chesscom = TextEditingController(
    text: widget.accounts[GameSite.chesscom]?.username ?? '',
  );

  @override
  void dispose() {
    _lichess.dispose();
    _chesscom.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(
    context,
  ).pop((lichess: _lichess.text.trim(), chesscom: _chesscom.text.trim()));

  Widget _field(TextEditingController controller, String label, bool first) =>
      TextField(
        controller: controller,
        autofocus: first,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (_) => _save(),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('My accounts'),
      content: SizedBox(
        width: nameDialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_lichess, 'Lichess username', true),
            const SizedBox(height: Space.m),
            _field(_chesscom, 'Chess.com username', false),
            const SizedBox(height: Space.m),
            Text(
              'Only your username: your games are public. Leave one blank if '
              'you do not play there.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
