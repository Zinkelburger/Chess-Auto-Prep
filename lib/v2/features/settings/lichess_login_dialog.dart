import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/listening_state.dart';
import 'lichess_account.dart';
import 'setting_controls.dart';
import 'setting_rows.dart';

/// The explorer's sign-in door, using the same account and browser flow as
/// Settings. Dismissing it cancels a pending browser login.
Future<bool> showLichessLogin(
  BuildContext context,
  LichessAccountState account,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _LoginDialog(account: account),
  );
  if (account.status is Connecting) await account.cancel();
  return result ?? false;
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.account});
  final LichessAccountState account;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog>
    with ListeningState<_LoginDialog> {
  @override
  Listenable listenableOf(_LoginDialog widget) => widget.account;
  @override
  void initState() {
    super.initState();
    // Start only once the dialog is in the navigator, including re-login
    // when the saved credential was rejected.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.account.logIn());
    });
  }

  @override
  void changed() {
    if (!mounted) return;
    if (widget.account.status is SignedIn) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    return AlertDialog(
      title: const Text('Log in to Lichess'),
      content: SizedBox(
        width: 440,
        child: SettingRowView(
          row: SettingRow(
            'Lichess',
            AccountSetting(account),
            hint: account.problem ?? accountHint(account.status),
            warn: account.problem != null,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
