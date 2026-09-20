import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../ui/name_dialog.dart';
import '../../ui/theme.dart';

/// What the user asked for: a name and the side the repertoire is for.
typedef NewRepertoire = ({String name, Side side});

/// Asks for a new repertoire, or answers null when the user backed out.
///
/// The side is asked for here rather than later because it is written into
/// the chapter file as it is created, and a chapter with no moves has nothing
/// else to say which side it belongs to.
Future<NewRepertoire?> showNewRepertoireDialog(BuildContext context) =>
    showDialog<NewRepertoire>(
      context: context,
      builder: (context) => const _NewRepertoireDialog(),
    );

class _NewRepertoireDialog extends StatefulWidget {
  const _NewRepertoireDialog();

  @override
  State<_NewRepertoireDialog> createState() => _NewRepertoireDialogState();
}

class _NewRepertoireDialogState extends State<_NewRepertoireDialog> {
  final _field = TextEditingController();
  Side _side = Side.white;
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
    Navigator.of(context).pop((name: _field.text.trim(), side: _side));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create repertoire'),
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
                labelText: 'Repertoire name',
                hintText: 'My Sicilian',
                errorText: _problem,
              ),
              onChanged: (_) {
                if (_problem != null) setState(() => _problem = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: Space.l),
            Text('Playing side', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: Space.xs),
            SegmentedButton<Side>(
              segments: const [
                ButtonSegment(value: Side.white, label: Text('White')),
                ButtonSegment(value: Side.black, label: Text('Black')),
              ],
              selected: {_side},
              onSelectionChanged: (chosen) =>
                  setState(() => _side = chosen.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
