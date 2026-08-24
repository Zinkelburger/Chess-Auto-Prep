import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../theme/app_colors.dart';

/// The one place the two usernames are typed.
///
/// They used to be two boxes stapled permanently to the tactics home's right
/// pane — the first thing on a screen you open to train, on a pane that also
/// carries the games window, the puzzle counts and the filters. Setting up an
/// account is something you do once; it earns a button, not permanent screen
/// space. The button is on [AccountsCard], and Settings → Your chess usernames
/// opens this same dialog, so there is one form rather than two.
///
/// Values are committed on Save, not per keystroke: [AppState] notifies the
/// whole app, and a half-typed name landing in every "fetch games" form (and
/// firing a download) is what per-keystroke commit bought.
class AccountsDialog extends StatefulWidget {
  const AccountsDialog({super.key});

  @override
  State<AccountsDialog> createState() => _AccountsDialogState();
}

/// Open the accounts form. Resolves when it closes; true if names were saved.
Future<bool> showAccountsDialog(BuildContext context) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => const AccountsDialog(),
  );
  return saved ?? false;
}

class _AccountsDialogState extends State<AccountsDialog> {
  late final TextEditingController _lichess;
  late final TextEditingController _chesscom;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _lichess = TextEditingController(text: app.lichessUsername ?? '');
    _chesscom = TextEditingController(text: app.chesscomUsername ?? '');
  }

  @override
  void dispose() {
    _lichess.dispose();
    _chesscom.dispose();
    super.dispose();
  }

  void _save() {
    final app = context.read<AppState>();
    final lichess = _lichess.text.trim();
    final chesscom = _chesscom.text.trim();
    app.setLichessUsername(lichess.isEmpty ? null : lichess);
    app.setChesscomUsername(chesscom.isEmpty ? null : chesscom);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return AlertDialog(
      title: const Text('My accounts'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your public username on each site — no password, no login. '
              'Fill in the ones you play on and the app downloads those '
              'games.',
              style: TextStyle(fontSize: 12.5, color: AppColors.onSurfaceSoft),
            ),
            const SizedBox(height: 18),
            _SiteField(
              fieldKey: const Key('lichess-username-field'),
              site: 'Lichess',
              hint: 'e.g. DrNykterstein',
              controller: _lichess,
              lastFetch: app.lichessLastFetch,
              onSubmitted: _save,
            ),
            const SizedBox(height: 16),
            _SiteField(
              fieldKey: const Key('chesscom-username-field'),
              site: 'Chess.com',
              hint: 'e.g. MagnusCarlsen',
              controller: _chesscom,
              lastFetch: app.chesscomLastFetch,
              onSubmitted: _save,
            ),
            const SizedBox(height: 16),
            const Text(
              'Leave a box empty for a site you do not play on. You can '
              'change these any time.',
              style: TextStyle(fontSize: 11.5, color: AppColors.onSurfaceMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('accounts-save-button'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// One site: its name, the username box, and — only once there *is* a name —
/// when its games were last pulled down. An empty field has no download
/// history to report, and "Not downloaded yet" under a blank box reads as a
/// problem to fix rather than as the absence of an account.
class _SiteField extends StatefulWidget {
  const _SiteField({
    required this.fieldKey,
    required this.site,
    required this.hint,
    required this.controller,
    required this.lastFetch,
    required this.onSubmitted,
  });

  /// Keyed for the boot integration test, which types a username in here to
  /// drive a download.
  final Key fieldKey;
  final String site;
  final String hint;
  final TextEditingController controller;
  final DateTime? lastFetch;
  final VoidCallback onSubmitted;

  @override
  State<_SiteField> createState() => _SiteFieldState();
}

class _SiteFieldState extends State<_SiteField> {
  @override
  Widget build(BuildContext context) {
    final filled = widget.controller.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.site,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        TextField(
          key: widget.fieldKey,
          controller: widget.controller,
          autofocus: widget.site == 'Lichess',
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: const TextStyle(color: AppColors.onSurfaceDisabled),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          // Only the caption below depends on the text; repaint it as typing
          // makes the field go from empty to filled.
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => widget.onSubmitted(),
        ),
        if (filled)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.lastFetch != null
                  ? 'Last downloaded ${formatAccountDate(widget.lastFetch!)}'
                  : 'Not downloaded yet',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
      ],
    );
  }
}

/// "Aug 20, 2026" — the date format both the dialog and [AccountsCard] use for
/// when a site's games were last fetched.
String formatAccountDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
