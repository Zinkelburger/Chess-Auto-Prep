import 'package:flutter/material.dart';

import 'theme.dart';

/// The longest name a file may be given. Every desktop filesystem this app
/// runs on allows more; 120 is what the old app settled on, and a name a
/// column cannot show is not a name anyone wants.
const maxNameLength = 120;

final _illegalCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// `CON`, `PRN.txt` and friends: names Windows gives to devices, which no
/// file may take even on the drive where this app is storing them.
final _deviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);

/// What is wrong with [name] as a file or folder name, or null when nothing
/// is. A name has to work on every platform the user's Documents folder might
/// be synced to, so Windows' rules apply on Linux too.
String? nameProblem(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Please enter a name.';
  // Untrimmed: a trailing space survives the dialog but not every filesystem.
  if (name.endsWith(' ')) return 'Names cannot end with a dot or space.';
  if (trimmed == '.' || trimmed == '..') return 'That name is reserved.';
  // A folder whose name starts with a dot is hidden, by this app's own
  // listing and by every file manager, so the user would be making something
  // they could never open again.
  if (trimmed.startsWith('.')) {
    return 'Names cannot start with a dot; the list would not show it.';
  }
  if (_illegalCharacters.hasMatch(trimmed)) {
    return r'Names cannot contain < > : " / \ | ? * or control characters.';
  }
  if (trimmed.endsWith('.')) return 'Names cannot end with a dot or space.';
  if (_deviceName.hasMatch(trimmed)) {
    return 'That name is reserved by the operating system.';
  }
  if (trimmed.length > maxNameLength) {
    return 'Names must be $maxNameLength characters or fewer.';
  }
  return null;
}

/// One more control under the name field, for a dialog that asks for a little
/// more than a name — the side a new repertoire plays.
///
/// It is given a way to ask the dialog to rebuild, so the caller keeps the
/// value its control collects and does not write the name field, its
/// validation and its buttons again to do it.
typedef NameDialogExtra =
    Widget Function(BuildContext context, VoidCallback changed);

/// Asks for a name and answers the trimmed one, or null when the user backed
/// out. A name the filesystem would refuse never leaves this dialog.
Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
  String initial = '',
  String? hint,
  NameDialogExtra? extra,
}) => showDialog<String>(
  context: context,
  builder: (context) => _NameDialog(
    title: title,
    label: label,
    confirm: confirm,
    initial: initial,
    hint: hint,
    extra: extra,
  ),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.label,
    required this.confirm,
    required this.initial,
    required this.hint,
    required this.extra,
  });

  final String title;
  final String label;
  final String confirm;
  final String initial;
  final String? hint;
  final NameDialogExtra? extra;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _field = TextEditingController(text: widget.initial);
  String? _problem;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = nameProblem(_field.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(_field.text.trim());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final extra = widget.extra;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: nameDialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _field,
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                errorText: _problem,
              ),
              onChanged: (_) {
                if (_problem != null) setState(() => _problem = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            if (extra != null) ...[
              const SizedBox(height: Space.l),
              extra(context, _changed),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}
