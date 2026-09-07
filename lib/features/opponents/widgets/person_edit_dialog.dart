/// Add or edit one person: name, US Chess ID, rating, online handles, notes.
///
/// The two US Chess buttons are the reason this is more than a form. **Look
/// up** turns an ID into the name and rating so a field typed from a wall
/// chart needs nothing else; **Find** goes the other way, from a name to the
/// matching IDs, for the regular whose ID you never wrote down.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../models/person_record.dart';
import '../services/uscf_client.dart';

class PersonEditDialog extends StatefulWidget {
  const PersonEditDialog({
    super.key,
    this.person,
    this.initialName = '',
    this.uscf,
    this.validateName,
  });

  /// Null to create a new person.
  final PersonRecord? person;

  /// Name to start with when creating (what the user typed into a search).
  final String initialName;

  /// Injectable for tests; a real client otherwise.
  final UscfClient? uscf;

  /// Reject a name (returns the message) — the caller knows the directory.
  final String? Function(String name)? validateName;

  @override
  State<PersonEditDialog> createState() => _PersonEditDialogState();
}

class _PersonEditDialogState extends State<PersonEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _uscfId;
  late final TextEditingController _rating;
  late final TextEditingController _chesscom;
  late final TextEditingController _lichess;
  late final TextEditingController _notes;
  late final UscfClient _uscf;

  String? _nameError;
  String? _uscfError;
  String? _uscfSummary;
  bool _busy = false;
  List<UscfMember>? _matches;

  @override
  void initState() {
    super.initState();
    final p = widget.person;
    _name = TextEditingController(text: p?.name ?? widget.initialName);
    _uscfId = TextEditingController(text: p?.uscfId ?? '');
    _rating = TextEditingController(text: p?.rating?.toString() ?? '');
    _chesscom = TextEditingController(text: p?.chesscom ?? '');
    _lichess = TextEditingController(text: p?.lichess ?? '');
    _notes = TextEditingController(text: p?.notes ?? '');
    _uscf = widget.uscf ?? UscfClient();
  }

  @override
  void dispose() {
    _name.dispose();
    _uscfId.dispose();
    _rating.dispose();
    _chesscom.dispose();
    _lichess.dispose();
    _notes.dispose();
    if (widget.uscf == null) _uscf.close();
    super.dispose();
  }

  Future<void> _lookUpId() async {
    setState(() {
      _busy = true;
      _uscfError = null;
      _uscfSummary = null;
      _matches = null;
    });
    try {
      final m = await _uscf.member(_uscfId.text);
      if (!mounted) return;
      setState(() {
        _uscfId.text = m.id;
        if (_name.text.trim().isEmpty) _name.text = m.name;
        if (m.rating != null) _rating.text = '${m.rating}';
        _uscfSummary = [
          m.name,
          m.summary,
        ].where((s) => s.isNotEmpty).join(' · ');
      });
    } on UscfException catch (e) {
      if (mounted) setState(() => _uscfError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _findByName() async {
    final q = _name.text.trim();
    if (q.length < 2) {
      setState(() => _nameError = 'Type a name to search for.');
      return;
    }
    setState(() {
      _busy = true;
      _nameError = null;
      _uscfError = null;
      _uscfSummary = null;
      _matches = null;
    });
    try {
      final found = await _uscf.search(q);
      if (!mounted) return;
      setState(() {
        _matches = found;
        if (found.isEmpty) _uscfError = 'US Chess has nobody named "$q".';
      });
    } on UscfException catch (e) {
      if (mounted) setState(() => _uscfError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _useMatch(UscfMember m) {
    setState(() {
      _uscfId.text = m.id;
      if (m.rating != null) _rating.text = '${m.rating}';
      _name.text = m.name;
      _matches = null;
      _uscfSummary = [m.name, m.summary].where((s) => s.isNotEmpty).join(' · ');
    });
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
    final rating = int.tryParse(_rating.text.trim());
    final existing = widget.person;
    final result = existing == null
        ? PersonRecord.create(
            name: name,
            uscfId: _uscfId.text,
            chesscom: _chesscom.text,
            lichess: _lichess.text,
            rating: rating,
            notes: _notes.text.trimRight(),
          )
        : existing.copyWith(
            name: name,
            uscfId: _uscfId.text,
            clearUscfId: _uscfId.text.trim().isEmpty,
            chesscom: _chesscom.text,
            clearChesscom: _chesscom.text.trim().isEmpty,
            lichess: _lichess.text,
            clearLichess: _lichess.text.trim().isEmpty,
            rating: rating,
            clearRating: rating == null,
            notes: _notes.text.trimRight(),
          );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.person != null;
    return AlertDialog(
      title: Text(editing ? 'Edit ${widget.person!.name}' : 'New person'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('person-name'),
                      controller: _name,
                      autofocus: !editing,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) {
                        if (_nameError != null) {
                          setState(() => _nameError = null);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: 'Name',
                        isDense: true,
                        errorText: _nameError,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: OutlinedButton(
                      key: const Key('person-find-uscf'),
                      onPressed: _busy ? null : _findByName,
                      child: const Text('Find on US Chess'),
                    ),
                  ),
                ],
              ),
              if (_matches != null && _matches!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _MatchList(matches: _matches!, onPick: _useMatch),
              ],
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: const Key('person-uscf-id'),
                      controller: _uscfId,
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _lookUpId(),
                      decoration: const InputDecoration(
                        labelText: 'US Chess ID',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: OutlinedButton(
                      key: const Key('person-lookup-uscf'),
                      onPressed: _busy ? null : _lookUpId,
                      child: const Text('Look up'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: const Key('person-rating'),
                      controller: _rating,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Rating',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              if (_busy || _uscfSummary != null || _uscfError != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (_busy) ...[
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        _busy
                            ? 'Asking US Chess…'
                            : (_uscfError ?? _uscfSummary ?? ''),
                        key: const Key('person-uscf-status'),
                        style: AppTextStyles.caption.copyWith(
                          color: _uscfError != null
                              ? AppColors.danger
                              : AppColors.onSurfaceMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('person-chesscom'),
                      controller: _chesscom,
                      decoration: const InputDecoration(
                        labelText: 'Chess.com username',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('person-lichess'),
                      controller: _lichess,
                      decoration: const InputDecoration(
                        labelText: 'Lichess username',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('person-notes'),
                controller: _notes,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('person-save'),
          onPressed: _save,
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// The people US Chess found for a name, one per row; tapping one fills the
/// form.
class _MatchList extends StatelessWidget {
  const _MatchList({required this.matches, required this.onPick});

  final List<UscfMember> matches;
  final ValueChanged<UscfMember> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final m in matches.take(12))
            ListTile(
              key: Key('uscf-match-${m.id}'),
              dense: true,
              title: Text(m.name),
              subtitle: Text(
                [m.id, m.summary].where((s) => s.isNotEmpty).join(' · '),
                style: AppTextStyles.caption,
              ),
              onTap: () => onPick(m),
            ),
        ],
      ),
    );
  }
}
