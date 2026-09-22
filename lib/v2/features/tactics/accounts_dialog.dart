import 'package:flutter/material.dart';

import '../../chess/tactics/game_ids.dart';
import '../../storage/my_accounts.dart';
import '../../ui/theme.dart';

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
