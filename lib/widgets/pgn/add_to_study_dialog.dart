/// Picker for "Add line to study": an editable chapter name, an explicit
/// new-study action, and a searchable list of existing studies.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/repertoire_metadata.dart';
import '../../services/storage/storage_factory.dart';
import '../../theme/app_colors.dart';
import '../common/name_entry_dialog.dart';
import '../study/study_name_dialog.dart' show sanitizeStudyName;

/// Outcome of [AddToStudyDialog]: exactly one of [existingPath] /
/// [newStudyName] is set.
class AddToStudyResult {
  final String? existingPath;
  final String? existingName;
  final String? newStudyName;
  final String chapterName;

  const AddToStudyResult({
    this.existingPath,
    this.existingName,
    this.newStudyName,
    required this.chapterName,
  });

  String get studyName => existingName ?? newStudyName ?? '';
}

class AddToStudyDialog extends StatefulWidget {
  final String initialChapterName;
  final String title;
  final String? selectionSummary;

  /// A study to list first, labelled as the prep file — an opponent's, when
  /// Player Analysis knows who it is looking at.
  final String? preferredPath;

  const AddToStudyDialog({
    super.key,
    required this.initialChapterName,
    this.title = 'Add line to study',
    this.selectionSummary,
    this.preferredPath,
  });

  @override
  State<AddToStudyDialog> createState() => _AddToStudyDialogState();
}

class _AddToStudyDialogState extends State<AddToStudyDialog> {
  late final TextEditingController _chapterCtrl;
  final TextEditingController _searchCtrl = TextEditingController();

  List<RepertoireMetadata>? _studies; // null while loading
  String _query = '';

  @override
  void initState() {
    super.initState();
    _chapterCtrl = TextEditingController(text: widget.initialChapterName);
    unawaited(_loadStudies());
  }

  Future<void> _loadStudies() async {
    final studies = await StorageFactory.instance.listStudyFiles();
    if (mounted) setState(() => _studies = studies);
  }

  @override
  void dispose() {
    _chapterCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _chapterName {
    final name = _chapterCtrl.text.trim();
    return name.isEmpty ? widget.initialChapterName : name;
  }

  bool _isPreferred(RepertoireMetadata s) =>
      widget.preferredPath != null && s.filePath == widget.preferredPath;

  List<RepertoireMetadata> get _filtered {
    final studies = _studies ?? const [];
    final q = _query.toLowerCase();
    final matching = [
      for (final s in studies)
        if (q.isEmpty || s.name.toLowerCase().contains(q)) s,
    ];
    // The prep file first, whatever the alphabet says.
    final preferred = matching.where(_isPreferred).toList();
    return [...preferred, ...matching.where((s) => !_isPreferred(s))];
  }

  void _pickExisting(RepertoireMetadata study) {
    Navigator.pop(
      context,
      AddToStudyResult(
        existingPath: study.filePath,
        existingName: study.name,
        chapterName: _chapterName,
      ),
    );
  }

  Future<void> _createNew() async {
    final taken = {
      for (final study in _studies ?? <RepertoireMetadata>[])
        study.name.toLowerCase(),
    };
    var suggested = 'New study';
    for (var suffix = 2; taken.contains(suggested.toLowerCase()); suffix++) {
      suggested = 'New study ($suffix)';
    }
    final name = await showNameEntryDialog(
      context,
      title: 'Add new study',
      fieldLabel: 'Study name',
      confirmLabel: 'Create and add',
      initialValue: suggested,
      allowUnchanged: true,
      validate: (value) {
        final safe = sanitizeStudyName(value);
        if (safe.isEmpty) return 'Please enter a study name.';
        if (taken.contains(safe.toLowerCase())) {
          return 'A study with this name already exists.';
        }
        return null;
      },
    );
    if (name == null || !mounted) return;
    Navigator.pop(
      context,
      AddToStudyResult(
        newStudyName: sanitizeStudyName(name),
        chapterName: _chapterName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final studies = _studies;
    final filtered = _filtered;

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.selectionSummary != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.selectionSummary!),
              )
            else
              TextField(
                controller: _chapterCtrl,
                decoration: const InputDecoration(
                  labelText: 'Chapter name',
                  isDense: true,
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: studies == null ? null : _createNew,
              icon: const Icon(Icons.add),
              label: const Text('Add new study'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search existing studies',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (v) {
                if (!mounted) return;
                setState(() => _query = v.trim());
              },
              onSubmitted: (_) {
                if (!mounted) return;
                final matches = _filtered;
                if (matches.length == 1) _pickExisting(matches.first);
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: studies == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (filtered.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              studies.isEmpty
                                  ? 'No studies yet. Use Add new study to create one.'
                                  : 'No studies match your search.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.onSurfaceMuted,
                              ),
                            ),
                          ),
                        for (final s in filtered)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.menu_book_outlined,
                              size: 20,
                            ),
                            title: Text(s.name),
                            subtitle: Text(
                              '${_isPreferred(s) ? 'Prep file · ' : ''}'
                              '${s.gameCount} chapter'
                              '${s.gameCount == 1 ? '' : 's'}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            onTap: () => _pickExisting(s),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
