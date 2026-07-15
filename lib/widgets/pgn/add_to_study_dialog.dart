/// Picker for "Add line to study": an editable chapter name, a search bar,
/// and the list of existing studies. Typing a name that matches no study
/// offers creating a new one with that name.
library;

import 'package:flutter/material.dart';

import '../../models/repertoire_metadata.dart';
import '../../services/storage/storage_factory.dart';

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

  const AddToStudyDialog({super.key, required this.initialChapterName});

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
    _loadStudies();
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

  List<RepertoireMetadata> get _filtered {
    final studies = _studies ?? const [];
    if (_query.isEmpty) return studies;
    final q = _query.toLowerCase();
    return [
      for (final s in studies)
        if (s.name.toLowerCase().contains(q)) s,
    ];
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

  void _createNew(String name) {
    final safe = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    if (safe.isEmpty) return;
    Navigator.pop(
      context,
      AddToStudyResult(newStudyName: safe, chapterName: _chapterName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final studies = _studies;
    final filtered = _filtered;
    final query = _query.trim();
    final hasExactMatch = filtered.any(
      (s) => s.name.toLowerCase() == query.toLowerCase(),
    );

    return AlertDialog(
      title: const Text('Add line to study'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _chapterCtrl,
              decoration: const InputDecoration(
                labelText: 'Chapter name',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search studies — or type a new study name',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
              onSubmitted: (v) {
                // Enter picks the single match, or creates the typed study.
                if (filtered.length == 1) {
                  _pickExisting(filtered.first);
                } else if (filtered.isEmpty && v.trim().isNotEmpty) {
                  _createNew(v);
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: studies == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (query.isNotEmpty && !hasExactMatch)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.add, size: 20),
                            title: Text('Create study "$query"'),
                            onTap: () => _createNew(query),
                          ),
                        if (filtered.isEmpty && query.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No studies yet — type a name above to '
                              'create one.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey[500]),
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
                              '${s.gameCount} chapter'
                              '${s.gameCount == 1 ? '' : 's'}',
                              style: const TextStyle(fontSize: 11),
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
