import 'package:flutter/material.dart';

import '../storage/chapter_files.dart';
import '../ui/name_dialog.dart';
import '../ui/search_field.dart';
import '../ui/theme.dart';
import 'study_choice.dart';

/// The answer of [showStudyPicker]: the study, and the chapter's name when
/// one chapter is going in (empty for `Chapter N`).
typedef StudyPick = ({StudyChoice into, String name});

/// The one picker every "Add to study" opens: the chapter's name when one
/// chapter is going in ([chapter]; null for several, [count] of them),
/// `New study…`, and the studies, searchable as they are typed. A study is
/// picked with a click, or with Enter when the search leaves one.
Future<StudyPick?> showStudyPicker(
  BuildContext context, {
  required List<ChapterRef> studies,
  required String? chapter,
  required int count,
}) => showDialog<StudyPick>(
  context: context,
  builder: (context) =>
      _StudyPicker(studies: studies, chapter: chapter, count: count),
);

class _StudyPicker extends StatefulWidget {
  const _StudyPicker({
    required this.studies,
    required this.chapter,
    required this.count,
  });

  final List<ChapterRef> studies;
  final String? chapter;
  final int count;

  @override
  State<_StudyPicker> createState() => _StudyPickerState();
}

class _StudyPickerState extends State<_StudyPicker> {
  late final _name = TextEditingController(text: widget.chapter ?? '');
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  List<ChapterRef> get _matches {
    final needle = _query.trim().toLowerCase();
    return [
      for (final study in widget.studies)
        if (study.name.toLowerCase().contains(needle)) study,
    ];
  }

  void _searched(String query) {
    if (mounted) setState(() => _query = query);
  }

  void _pick(StudyChoice into) {
    if (!mounted) return;
    Navigator.of(context).pop((into: into, name: _name.text.trim()));
  }

  Future<void> _newStudy() async {
    final name = await showNameDialog(
      context,
      title: 'New study',
      label: 'Study name',
      confirm: 'Create',
      initial: _query.trim(),
    );
    if (name != null) _pick(NewStudy(name));
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return AlertDialog(
      title: Text(
        widget.chapter == null
            ? 'Add ${widget.count} chapters to a study'
            : 'Add to study',
      ),
      content: SizedBox(
        width: nameDialogWidth,
        height: choiceDialogHeight + Space.xl * 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.chapter != null) ...[
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Chapter name'),
              ),
              const SizedBox(height: Space.m),
            ],
            SearchField(
              controller: _search,
              hint: 'Type a study',
              autofocus: true,
              onChanged: _searched,
              onSubmitted: (_) {
                if (matches.length == 1) _pick(IntoStudy(matches.single));
              },
            ),
            const SizedBox(height: Space.s),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add, size: IconSize.action),
              title: const Text('New study…'),
              onTap: () => _newStudy(),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Space.m),
                      child: Text(
                        widget.studies.isEmpty
                            ? 'No studies yet'
                            : 'Nothing matches "$_query".',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        title: Text(
                          matches[index].name,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _pick(IntoStudy(matches[index])),
                      ),
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
      ],
    );
  }
}
