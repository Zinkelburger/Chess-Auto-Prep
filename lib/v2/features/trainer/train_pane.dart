import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../workspace/move_field.dart';
import 'lesson_view.dart';
import 'line_list.dart';
import 'trainer.dart';
import 'trainer_words.dart';

/// The Train tab of the reading card: the lines of the chapter, or of its
/// repertoire, with where each stands and the two ways in — Review what is
/// due, Learn what is new — or, while a sitting runs, the lesson.
class TrainPane extends StatefulWidget {
  const TrainPane({
    super.key,
    required this.trainer,
    required this.moves,
    required this.onRead,
    this.offerBuilder = true,
    this.bookChip,
    this.onImport,
    this.onSettings,
  });

  final Trainer trainer;
  final VoidCallback? onImport;
  final VoidCallback? onSettings;

  /// Which book is trained, shown while the scope is the book.
  final Widget? bookChip;

  /// The move field under the board, which a lesson types a move into.
  final MoveEntry moves;

  /// Sends a line to be read: to the board, the Moves tab or the builder.
  final ValueChanged<LineToRead> onRead;

  /// Whether a line offers `Open in Builder`.
  final bool offerBuilder;

  @override
  State<TrainPane> createState() => _TrainPaneState();
}

class _TrainPaneState extends State<TrainPane> {
  @override
  void initState() {
    super.initState();
    widget.trainer.show();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.trainer,
      builder: (context, _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final trainer = widget.trainer;
    if (trainer.lesson case final lesson?) {
      return LessonView(lesson: lesson, trainer: trainer, moves: widget.moves);
    }
    return switch (trainer.state) {
      TrainerIdle() ||
      TrainerLoading() => const _Sentence('Reading training progress…'),
      // The scope stays in reach: a book trains with nothing open.
      TrainerEmpty(:final why) => Padding(
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TrainScopeButtons(trainer: trainer),
            if (widget.onImport != null) ...[
              const SizedBox(height: Space.m),
              FilledButton.icon(
                onPressed: widget.onImport,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import course PGN…'),
              ),
              const SizedBox(height: Space.s),
              const Text(
                'Choose a downloaded Chessable course or repertoire PGN.',
              ),
            ],
            if (trainer.scope == TrainScope.book) ?widget.bookChip,
            const SizedBox(height: Space.s),
            Text(
              emptyReason(why),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      TrainerFailed(:final failure) => _Failed(
        sentence: progressProblem(failure, doing: 'read the training progress'),
        onRetry: trainer.reload,
      ),
      final TrainerReady ready => LineList(
        trainer: trainer,
        ready: ready,
        onRead: widget.onRead,
        offerBuilder: widget.offerBuilder,
        bookChip: widget.bookChip,
        onImport: widget.onImport,
        onSettings: widget.onSettings,
      ),
    };
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.m),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.sentence, required this.onRetry});

  final String sentence;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Space.m),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sentence),
        const SizedBox(height: Space.s),
        OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
