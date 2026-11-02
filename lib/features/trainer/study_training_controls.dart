import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/study.dart';
import '../../ui/form_dialog.dart';
import '../../ui/status_bar.dart';
import '../../ui/theme.dart';
import 'trainer.dart';
import 'trainer_state.dart';
import '../../ui/segments.dart';

/// Study scope and practice identity remain available before training is ready.
class StudyTrainingControls extends StatelessWidget {
  const StudyTrainingControls({super.key, required this.trainer});
  final Trainer trainer;

  Future<void> _sides(BuildContext context) async {
    final document = trainer.studyDocument;
    if (document == null) return;
    final say = StatusScope.of(context);
    final sides = await showDialog<Map<int, Side>>(
      context: context,
      builder: (_) => _Sides(document: document),
    );
    if (sides == null || !context.mounted) return;
    final problem = trainer.setStudySides(document, sides);
    if (problem != null) say(problem);
  }

  @override
  Widget build(BuildContext context) {
    final lines = trainer.studyDocument!.lines;
    final missing = lines
        .where((line) => studyTrainingSide(line) == null)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Segments<TrainScope>(
              segments: const [
                ButtonSegment(
                  value: TrainScope.studyChapter,
                  label: Text('This chapter'),
                ),
                ButtonSegment(
                  value: TrainScope.chapter,
                  label: Text('Whole study'),
                ),
              ],
              selected: trainer.scope == TrainScope.studyChapter
                  ? TrainScope.studyChapter
                  : TrainScope.chapter,
              onChanged: (value) => trainer.setScope(value),
            ),
            const SizedBox(width: Space.s),
            TextButton(
              onPressed: () => _sides(context),
              child: const Text('Training sides…'),
            ),
          ],
        ),
        if (missing > 0)
          Text(
            '$missing ${missing == 1 ? 'chapter needs' : 'chapters need'} a training side. Ready chapters can be practiced.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _Sides extends StatefulWidget {
  const _Sides({required this.document});
  final Chapter document;
  @override
  State<_Sides> createState() => _SidesState();
}

class _SidesState extends State<_Sides> {
  late final _sides = <int, Side>{
    for (final (index, line) in widget.document.lines.indexed)
      if (line.isWhole && studyTrainingSide(line) != null)
        index: studyTrainingSide(line)!,
  };

  void _fill(Side side) => setState(() {
    for (final (index, line) in widget.document.lines.indexed) {
      if (line.isWhole) _sides.putIfAbsent(index, () => side);
    }
  });

  /// One chapter with the side to train it from, or why it has none.
  Widget _row(int index) {
    final line = widget.document.lines[index];
    final name = studyChapterName(
      line,
      index: index,
      study: studyNameIn(widget.document.lines),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          Expanded(child: Text('${index + 1}. $name')),
          const SizedBox(width: Space.s),
          if (!line.isWhole)
            const Text('Unreadable chapter')
          else
            Semantics(
              label: 'Training side for $name',
              child: Segments<Side>(
                segments: const [
                  ButtonSegment(value: Side.white, label: Text('White')),
                  ButtonSegment(value: Side.black, label: Text('Black')),
                ],
                selected: _sides[index],
                emptyAllowed: !_sides.containsKey(index),
                onChanged: (value) => setState(() => _sides[index] = value),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: 'Choose training sides',
    width: dialogWide,
    confirm: 'Save sides',
    onConfirm: _sides.isEmpty ? null : () => Navigator.pop(context, _sides),
    body: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose the side you will play. The board orientation stays unchanged.',
          ),
          Wrap(
            spacing: Space.s,
            children: [
              TextButton(
                onPressed: () => _fill(Side.white),
                child: const Text('Set missing to White'),
              ),
              TextButton(
                onPressed: () => _fill(Side.black),
                child: const Text('Set missing to Black'),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.document.lines.length,
              itemBuilder: (context, index) => _row(index),
            ),
          ),
        ],
      ),
    ),
  );
}
