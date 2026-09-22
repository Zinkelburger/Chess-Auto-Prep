/// Picker for "Add line to study": an editable chapter name, an explicit
/// new-study action, and a searchable list of existing studies.
library;

import 'dart:async';
import '../../l10n/generated/app_localizations.dart';

import 'package:flutter/material.dart';

import '../../features/repertoires/models/repertoire_metadata.dart';
import '../../design_system/components/name_entry_dialog.dart';
import '../../design_system/theme/app_typography.dart';
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
  final Future<List<RepertoireMetadata>> Function() loadStudies;
  final String initialChapterName;
  final String? title;
  final String? selectionSummary;

  /// A study to list first, labelled as the prep file — an opponent's, when
  /// Player Analysis knows who it is looking at.
  final String? preferredPath;

  const AddToStudyDialog({
    super.key,
    required this.initialChapterName,
    required this.loadStudies,
    this.title,
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
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _chapterCtrl = TextEditingController(text: widget.initialChapterName);
    unawaited(_loadStudies());
  }

  Future<void> _loadStudies() async {
    try {
      final studies = await widget.loadStudies();
      if (mounted) {
        setState(() {
          _studies = List.unmodifiable(studies);
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
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
    var suggested = AppLocalizations.of(context).studyNewStudy;
    for (var suffix = 2; taken.contains(suggested.toLowerCase()); suffix++) {
      suggested = AppLocalizations.of(context).studyNumberedNew(suffix);
    }
    final name = await showNameEntryDialog(
      context,
      title: AppLocalizations.of(context).studyAddNewStudy,
      fieldLabel: AppLocalizations.of(context).studyStudyName,
      confirmLabel: AppLocalizations.of(context).studyCreateAndAdd,
      initialValue: suggested,
      allowUnchanged: true,
      validate: (value) {
        final safe = sanitizeStudyName(value);
        if (safe.isEmpty) return AppLocalizations.of(context).studyNameRequired;
        if (taken.contains(safe.toLowerCase())) {
          return AppLocalizations.of(context).studyNameExists;
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
    final l10n = AppLocalizations.of(context);
    final studies = _studies;
    final filtered = _filtered;

    return AlertDialog(
      title: Text(widget.title ?? l10n.studyAddLine),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadFailed)
              TextButton.icon(
                onPressed: _loadStudies,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.studyListRetry),
              ),
            if (widget.selectionSummary != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.selectionSummary!),
              )
            else
              TextField(
                controller: _chapterCtrl,
                decoration: InputDecoration(
                  labelText: l10n.studyChapterName,
                  isDense: true,
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: studies == null ? null : _createNew,
              icon: const Icon(Icons.add),
              label: Text(l10n.studyAddNewStudy),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.studySearchExisting,
                prefixIcon: const Icon(Icons.search, size: 18),
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
                                  ? l10n.studyNoStudiesToAdd
                                  : l10n.studyNoStudiesMatch,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
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
                              _isPreferred(s)
                                  ? l10n.studyPreferredChapterCount(s.gameCount)
                                  : l10n.studyChapterCount(s.gameCount),
                              style: AppTypography.caption(context),
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
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
