/// Name + color prompt for "Generate repertoire from games" in the PGN
/// viewer. Split out of `pgn_viewer_screen.dart`; the widget stays private —
/// callers go through [showGenerateRepertoireDialog].
library;

import 'package:flutter/material.dart';

/// Show the dialog; resolves to the chosen repertoire name and color, or
/// null if cancelled.
Future<({String name, String color})?> showGenerateRepertoireDialog(
  BuildContext context, {
  required String suggestedName,
}) {
  return showDialog<({String name, String color})>(
    context: context,
    builder: (ctx) => _GenerateRepertoireDialog(suggestedName: suggestedName),
  );
}

class _GenerateRepertoireDialog extends StatefulWidget {
  final String suggestedName;
  const _GenerateRepertoireDialog({required this.suggestedName});

  @override
  State<_GenerateRepertoireDialog> createState() =>
      _GenerateRepertoireDialogState();
}

class _GenerateRepertoireDialogState extends State<_GenerateRepertoireDialog> {
  late final TextEditingController _nameCtrl;
  String _color = 'White';

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.suggestedName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Generate Repertoire from Games'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Repertoire name',
                hintText: 'e.g. Caruana Kan',
              ),
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            const Text('Color'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'White', label: Text('White')),
                ButtonSegment(value: 'Black', label: Text('Black')),
              ],
              selected: {_color},
              onSelectionChanged: (s) => setState(() => _color = s.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create & Generate'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name: name, color: _color));
  }
}
