/// The Lichess "Edit chapter" dialog: name, orientation and the chapter's
/// PGN tags (everything the study does not generate itself — `Result`,
/// `ECO`, `Annotator`, a `ChapterURL` it was imported with, …).
library;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../models/study_document.dart';
import '../../theme/app_text_styles.dart';

/// The edited fields.  [headers] is the complete replacement tag set.
class ChapterEdit {
  const ChapterEdit({
    required this.name,
    required this.orientation,
    required this.headers,
  });

  final String name;
  final Side orientation;
  final Map<String, String> headers;
}

Future<ChapterEdit?> showEditChapterDialog(
  BuildContext context, {
  required StudyChapter chapter,
}) => showDialog<ChapterEdit>(
  context: context,
  builder: (_) => _EditChapterDialog(chapter: chapter),
);

class _EditChapterDialog extends StatefulWidget {
  const _EditChapterDialog({required this.chapter});

  final StudyChapter chapter;

  @override
  State<_EditChapterDialog> createState() => _EditChapterDialogState();
}

class _TagRow {
  _TagRow(String key, String value)
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _EditChapterDialogState extends State<_EditChapterDialog> {
  late final _name = TextEditingController(text: widget.chapter.name)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.chapter.name.length,
    );
  late Side _orientation = widget.chapter.orientation;
  late final List<_TagRow> _tags = [
    for (final entry in widget.chapter.headers.entries)
      _TagRow(entry.key, entry.value),
  ];
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    for (final tag in _tags) {
      tag.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A chapter needs a name.');
      return;
    }
    final headers = <String, String>{};
    for (final tag in _tags) {
      final key = tag.key.text.trim();
      if (key.isEmpty) continue;
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(key)) {
        setState(() => _error = 'Tag names are letters and digits: "$key".');
        return;
      }
      if (StudyChapter.ownedHeaders.contains(key)) {
        setState(() => _error = '$key is written by the study; edit it above.');
        return;
      }
      headers[key] = tag.value.text.trim();
    }
    Navigator.of(
      context,
    ).pop(ChapterEdit(name: name, orientation: _orientation, headers: headers));
  }

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: AppTextStyles.monoFamily, fontSize: 12);
    return AlertDialog(
      title: const Text('Edit chapter'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              const Text('Orientation', style: AppTextStyles.caption),
              const SizedBox(height: 6),
              SegmentedButton<Side>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: Side.white, label: Text('White')),
                  ButtonSegment(value: Side.black, label: Text('Black')),
                ],
                selected: {_orientation},
                onSelectionChanged: (s) =>
                    setState(() => _orientation = s.single),
              ),
              const SizedBox(height: 16),
              const Text('PGN tags', style: AppTextStyles.caption),
              const SizedBox(height: 6),
              for (final (i, tag) in _tags.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: tag.key,
                          style: mono,
                          decoration: const InputDecoration(
                            hintText: 'Tag',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(() => _error = null),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: tag.value,
                          style: mono,
                          decoration: const InputDecoration(
                            hintText: 'Value',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: 'Remove tag',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          final removed = _tags.removeAt(i);
                          setState(() {});
                          // The row's fields are still mounted this frame.
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => removed.dispose(),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add tag'),
                onPressed: () => setState(() => _tags.add(_TagRow('', ''))),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
