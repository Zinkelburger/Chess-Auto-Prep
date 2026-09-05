/// Name, date and round count of a tournament — for creating one and for
/// editing one.
library;

import 'package:flutter/material.dart';

class TournamentDetails {
  const TournamentDetails({required this.name, this.date, this.rounds});
  final String name;
  final String? date;
  final int? rounds;
}

class TournamentDetailsDialog extends StatefulWidget {
  const TournamentDetailsDialog({super.key, this.initial, this.validateName});

  final TournamentDetails? initial;
  final String? Function(String name)? validateName;

  @override
  State<TournamentDetailsDialog> createState() =>
      _TournamentDetailsDialogState();
}

class _TournamentDetailsDialogState extends State<TournamentDetailsDialog> {
  late final TextEditingController _name;
  late final TextEditingController _date;
  late final TextEditingController _rounds;
  String? _nameError;
  String? _dateError;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _date = TextEditingController(text: widget.initial?.date ?? '');
    _rounds = TextEditingController(
      text: widget.initial?.rounds?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _date.dispose();
    _rounds.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'A name is needed.');
      return;
    }
    final problem = widget.validateName?.call(name);
    if (problem != null) {
      setState(() => _nameError = problem);
      return;
    }
    final date = _date.text.trim();
    if (date.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      setState(() => _dateError = 'Use YYYY-MM-DD.');
      return;
    }
    Navigator.of(context).pop(
      TournamentDetails(
        name: name,
        date: date.isEmpty ? null : date,
        rounds: int.tryParse(_rounds.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? 'Tournament details' : 'New tournament'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('tournament-name'),
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _save(),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: 'Name',
                isDense: true,
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('tournament-date'),
                    controller: _date,
                    onChanged: (_) {
                      if (_dateError != null) setState(() => _dateError = null);
                    },
                    decoration: InputDecoration(
                      labelText: 'Date (YYYY-MM-DD)',
                      isDense: true,
                      errorText: _dateError,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: TextField(
                    key: const Key('tournament-rounds'),
                    controller: _rounds,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Rounds',
                      isDense: true,
                    ),
                  ),
                ),
              ],
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
          key: const Key('tournament-save'),
          onPressed: _save,
          child: Text(editing ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
