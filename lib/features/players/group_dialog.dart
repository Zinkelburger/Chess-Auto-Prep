import 'package:flutter/material.dart';

import '../../chess/players/player.dart';
import '../../ui/field_row.dart';
import '../../ui/file_names.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';

Future<PlayerGroup?> editGroup(BuildContext context, {PlayerGroup? group}) =>
    showDialog<PlayerGroup>(
      context: context,
      builder: (_) => _GroupDialog(group),
    );

class _GroupDialog extends StatefulWidget {
  const _GroupDialog(this.group);
  final PlayerGroup? group;
  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.group?.name ?? '');
  late final date = TextEditingController(
    text: widget.group?.fields['date'] as String? ?? '',
  );
  int rounds = 5;
  @override
  void initState() {
    super.initState();
    rounds = widget.group?.fields['rounds'] as int? ?? 5;
  }

  @override
  void dispose() {
    name.dispose();
    date.dispose();
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    Navigator.pop(
      context,
      (widget.group ?? PlayerGroup.create(name.text)).edited({
        'name': name.text.trim(),
        'date': date.text.trim().isEmpty ? null : date.text.trim(),
        'rounds': rounds,
      }),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.group == null ? 'New group' : 'Edit group'),
    content: SizedBox(
      width: nameDialogWidth,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Group name'),
              validator: (v) => nameProblem(v?.trim() ?? ''),
            ),
            const SizedBox(height: Space.m),
            TextFormField(
              controller: date,
              decoration: const InputDecoration(
                labelText: 'Event date (YYYY-MM-DD, optional)',
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final parsed = DateTime.tryParse(v);
                return parsed != null &&
                        parsed.toIso8601String().startsWith(v) &&
                        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v)
                    ? null
                    : 'Use a valid date: YYYY-MM-DD.';
              },
            ),
            const SizedBox(height: Space.m),
            FieldRow(
              label: 'Rounds',
              child: NumberField(
                label: 'Rounds',
                value: rounds,
                min: 1,
                max: 30,
                onChanged: (v) {
                  if (mounted) setState(() => rounds = v);
                },
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: save, child: const Text('Save group')),
    ],
  );
}
