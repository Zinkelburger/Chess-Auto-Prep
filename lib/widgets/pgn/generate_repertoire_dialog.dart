/// Name + color prompt for "Generate repertoire from games" in the PGN
/// viewer. Split out of `pgn_viewer_screen.dart`; the widget stays private —
/// callers go through [showGenerateRepertoireDialog].
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Show the dialog; resolves to the chosen repertoire name and color, or
/// null if cancelled.
Future<({String name, String color})?> showGenerateRepertoireDialog(
  BuildContext context, {
  required String suggestedName,
  int gameCount = 0,
}) {
  return showDialog<({String name, String color})>(
    context: context,
    builder: (ctx) => _GenerateRepertoireDialog(
      suggestedName: suggestedName,
      gameCount: gameCount,
    ),
  );
}

class _GenerateRepertoireDialog extends StatefulWidget {
  final String suggestedName;
  final int gameCount;
  const _GenerateRepertoireDialog({
    required this.suggestedName,
    required this.gameCount,
  });

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
    final n = widget.gameCount;
    return AlertDialog(
      title: const Text('Seed a Repertoire from These Games'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // What actually happens next, in one line — the old dialog jumped
            // straight to a name field and left "then what?" unanswered.
            Text(
              n > 0
                  ? 'The $n game${n == 1 ? '' : 's'} currently in view become '
                        'the seed. The Repertoire Builder opens next and '
                        'generates lines from them.'
                  : 'The games currently in view become the seed. The '
                        'Repertoire Builder opens next and generates lines '
                        'from them.',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
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
          child: const Text('Create & Open Builder'),
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
