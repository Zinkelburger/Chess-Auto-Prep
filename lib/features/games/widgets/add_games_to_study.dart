import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/study_controller.dart';
import '../../../models/pgn_game_entry.dart';
import '../../../models/study_document.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/pgn/add_to_study_dialog.dart';

/// Capture the source before any picker opens. Adding chapters never changes
/// the collection, its filters, or the active reader.
Future<void> addGamesToStudy(
  BuildContext context, {
  required List<PgnGameEntry> games,
  required int currentIndex,
  bool chooseGames = false,
}) async {
  if (games.isEmpty) return;
  final snapshots = [
    for (final game in games)
      (
        label: game.label,
        name:
            game.headers['ChapterName'] ??
            '${game.headers['White'] ?? 'White'} – ${game.headers['Black'] ?? 'Black'}',
        pgn: game.pgnText,
      ),
  ];
  var selected = [currentIndex.clamp(0, games.length - 1)];
  if (chooseGames) {
    final result = await showDialog<List<int>>(
      context: context,
      builder: (_) => StudyGameSelectionDialog(
        labels: [for (final game in snapshots) game.label],
        currentIndex: selected.single,
      ),
    );
    if (result == null || !context.mounted) return;
    selected = result;
  }
  final destination = await showDialog<AddToStudyResult>(
    context: context,
    builder: (_) => AddToStudyDialog(
      initialChapterName: snapshots[selected.first].name,
      title: 'Add to study',
      selectionSummary: selected.length == 1
          ? null
          : '${selected.length} games · one chapter per game',
    ),
  );
  if (destination == null || !context.mounted) return;
  final study = context.read<StudyController>();
  try {
    final path =
        destination.existingPath ??
        await StorageFactory.instance.studyFilePath(destination.newStudyName!);
    await study.addChaptersToStudyFile(path, [
      for (final index in selected)
        StudyChapter.fromGameText(
          snapshots[index].pgn,
          name: selected.length == 1
              ? destination.chapterName
              : snapshots[index].name,
        ),
    ]);
  } catch (error) {
    debugPrint('Add games to study failed: $error');
    if (context.mounted) {
      showAppSnackBar(
        context,
        'Could not add games to study. Please try again.',
        isError: true,
      );
    }
  }
}

class StudyGameSelectionDialog extends StatefulWidget {
  const StudyGameSelectionDialog({
    super.key,
    required this.labels,
    required this.currentIndex,
  });
  final List<String> labels;
  final int currentIndex;

  @override
  State<StudyGameSelectionDialog> createState() =>
      _StudyGameSelectionDialogState();
}

class _StudyGameSelectionDialogState extends State<StudyGameSelectionDialog> {
  late final Set<int> _selected = {widget.currentIndex};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Choose games for a study'),
    content: SizedBox(
      width: 560,
      height: 380,
      child: Column(
        children: [
          CheckboxListTile(
            title: Text('All ${widget.labels.length} games in this view'),
            subtitle: const Text('Your collection filters are respected.'),
            tristate: true,
            value: _selected.isEmpty
                ? false
                : _selected.length == widget.labels.length
                ? true
                : null,
            onChanged: (_) => setState(() {
              if (_selected.length == widget.labels.length) {
                _selected.clear();
              } else {
                _selected.addAll(Iterable.generate(widget.labels.length));
              }
            }),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: widget.labels.length,
              itemBuilder: (_, index) => CheckboxListTile(
                value: _selected.contains(index),
                title: Text(widget.labels[index]),
                subtitle: index == widget.currentIndex
                    ? const Text('Current game')
                    : null,
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _selected.add(index);
                  } else {
                    _selected.remove(index);
                  }
                }),
              ),
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
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(context, _selected.toList()..sort()),
        child: Text('Continue with ${_selected.length}'),
      ),
    ],
  );
}
