import 'package:flutter/material.dart';

import '../../ui/theme.dart';

/// Asks for a Lichess study link and answers what the user typed, or null
/// when they backed out.
///
/// [describe] says what a link is recognised as, or null when it is not one
/// the app can fetch; it comes from the owner, so this dialog knows nothing
/// about the service. What was recognised is echoed back on a line that is
/// always there, so it appearing does not push the button out from under the
/// pointer, and only a recognised link enables the button. The download
/// itself, and anything that goes wrong with it, belongs to the panel.
Future<String?> showImportStudyDialog(
  BuildContext context, {
  required String? Function(String input) describe,
}) => showDialog<String>(
  context: context,
  builder: (context) => _ImportDialog(describe: describe),
);

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.describe});

  final String? Function(String input) describe;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _url = TextEditingController();
  String? _recognised;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _typed(String text) {
    if (!mounted) return;
    setState(() => _recognised = widget.describe(text));
  }

  void _import() {
    if (_recognised != null) Navigator.of(context).pop(_url.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Import from URL'),
      content: SizedBox(
        width: nameDialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              onChanged: _typed,
              onSubmitted: (_) => _import(),
              decoration: const InputDecoration(
                labelText: 'Study link',
                hintText: 'lichess.org/study/abcd1234',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: Space.s),
            Text(_echo, style: text.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _recognised == null ? null : _import,
          child: const Text('Import'),
        ),
      ],
    );
  }

  String get _echo {
    if (_recognised case final recognised?) return recognised;
    if (_url.text.trim().isEmpty) {
      return 'Accepts lichess.org/study/<id> and '
          'lichess.org/study/<id>/<chapter>.';
    }
    return 'Not a Lichess study link.';
  }
}
