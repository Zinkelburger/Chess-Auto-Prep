/// "Add opponent" to a tournament: search the directory first, so a regular
/// is one tap, and fall through to a new person only when nobody matches.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/list_search_field.dart';
import '../models/person_record.dart';
import '../services/opponent_store.dart';
import 'person_edit_dialog.dart';

/// Pops with the person to add (already saved to the directory when new), or
/// null.
class AddOpponentDialog extends StatefulWidget {
  const AddOpponentDialog({
    super.key,
    required this.store,
    required this.excludeIds,
  });

  final OpponentStore store;

  /// People already in the field, hidden from the results.
  final Set<String> excludeIds;

  @override
  State<AddOpponentDialog> createState() => _AddOpponentDialogState();
}

class _AddOpponentDialogState extends State<AddOpponentDialog> {
  String _query = '';

  List<PersonRecord> get _results => widget.store
      .searchPeople(_query)
      .where((p) => !widget.excludeIds.contains(p.id))
      .toList();

  Future<void> _newPerson() async {
    final created = await showDialog<PersonRecord>(
      context: context,
      builder: (_) => PersonEditDialog(initialName: _query.trim()),
    );
    if (created == null || !mounted) return;
    final saved = await widget.store.savePerson(created);
    if (mounted) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final total = widget.store.people.length;
    return AlertDialog(
      title: const Text('Add opponent'),
      content: SizedBox(
        width: 460,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListSearchField(
              hintText: total == 0
                  ? 'Name'
                  : 'Search $total ${total == 1 ? 'person' : 'people'}',
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              onSubmitted: () {
                if (results.isEmpty) unawaited(_newPerson());
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                        _query.trim().isEmpty
                            ? 'Nobody in the directory yet.'
                            : 'Nobody matches "${_query.trim()}".',
                        style: const TextStyle(color: AppColors.onSurfaceMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final p = results[i];
                        return ListTile(
                          key: Key('add-opponent-${p.id}'),
                          dense: true,
                          title: Text(p.name),
                          subtitle: Text(
                            [
                              if (p.rating != null) '${p.rating}',
                              if (p.uscfId != null) 'USCF ${p.uscfId}',
                              if (p.handlesLine.isNotEmpty) p.handlesLine,
                            ].join(' · '),
                            style: AppTextStyles.caption,
                          ),
                          onTap: () => Navigator.of(context).pop(p),
                        );
                      },
                    ),
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
          key: const Key('add-opponent-new'),
          onPressed: _newPerson,
          child: Text(
            _query.trim().isEmpty ? 'New person…' : 'New: ${_query.trim()}',
          ),
        ),
      ],
    );
  }
}
