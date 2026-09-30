import 'package:flutter/material.dart';

import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/study.dart';
import '../../ui/theme.dart';

Future<Map<String, String>?> showStudyTags(
  BuildContext context,
  List<PgnHeader> tags,
) => showDialog<Map<String, String>>(
  context: context,
  builder: (_) => _Tags(tags: tags),
);

class _Tags extends StatefulWidget {
  const _Tags({required this.tags});
  final List<PgnHeader> tags;
  @override
  State<_Tags> createState() => _TagsState();
}

class _TagsState extends State<_Tags> {
  late final _rows = [
    for (final tag in widget.tags.whereType<PgnTag>())
      if (!studyOwnedTags.contains(tag.key)) _TagRow(tag.key, tag.value),
  ];
  final _removed = <_TagRow>[];
  String? _problem;
  @override
  void dispose() {
    for (final row in [..._rows, ..._removed]) {
      row.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Chapter PGN tags'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _rows)
              Padding(
                key: ObjectKey(row),
                padding: const EdgeInsets.only(bottom: Space.s),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: row.key,
                        decoration: const InputDecoration(labelText: 'Tag'),
                      ),
                    ),
                    const SizedBox(width: Space.s),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: row.value,
                        decoration: const InputDecoration(labelText: 'Value'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove tag',
                      onPressed: () {
                        if (mounted)
                          setState(() {
                            _rows.remove(row);
                            _removed.add(row);
                          });
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: () {
                if (mounted) setState(() => _rows.add(_TagRow('', '')));
              },
              icon: const Icon(Icons.add),
              label: const Text('Add tag'),
            ),
            if (_problem case final message?)
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      FilledButton(onPressed: _save, child: const Text('Save tags')),
    ],
  );
  void _save() {
    if (!mounted) return;
    final values = <String, String>{};
    for (final row in _rows) {
      final key = row.key.text.trim();
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(key)) {
        setState(
          () => _problem =
              'Use a tag name starting with a letter, followed by letters, digits or underscores.',
        );
        return;
      }
      if (studyOwnedTags.contains(key)) {
        setState(() => _problem = '$key belongs to the study.');
        return;
      }
      if (values.containsKey(key)) {
        setState(() => _problem = 'Each tag name can appear only once.');
        return;
      }
      values[key] = row.value.text;
    }
    if (values['Result'] case final result?) {
      if (!{'*', '1-0', '0-1', '1/2-1/2'}.contains(result)) {
        setState(() => _problem = 'Use a PGN result: *, 1-0, 0-1 or 1/2-1/2.');
        return;
      }
    }
    Navigator.pop(context, values);
  }
}

final class _TagRow {
  _TagRow(String key, String value)
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);
  final TextEditingController key, value;
  void dispose() {
    key.dispose();
    value.dispose();
  }
}
