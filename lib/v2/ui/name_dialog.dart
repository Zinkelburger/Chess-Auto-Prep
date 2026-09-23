import 'package:flutter/material.dart';

import 'file_names.dart';
import 'theme.dart';

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

  /// The name is what the field holds without the spaces around it, which
  /// is what is checked and what is answered: a space typed at either end
  /// is neither refused nor kept.
  void _submit() {
    if (!mounted) return;
    final name = _field.text.trim();
    final problem = nameProblem(name);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(name);
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
                if (mounted && _problem != null) {
                  setState(() => _problem = null);
                }
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
