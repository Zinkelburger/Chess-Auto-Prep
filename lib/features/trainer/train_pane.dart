import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../workspace/move_field.dart';
import 'lesson_view.dart';
import 'line_list.dart';
import 'trainer.dart';
import 'trainer_words.dart';
import 'training_home.dart';

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
    this.onStudy,
  });

  final Trainer trainer;
  final VoidCallback? onStudy;
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

  Widget _paused(Trainer trainer, String name) => Padding(
    padding: const EdgeInsets.all(Space.m),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Paused · $name'),
          const SizedBox(height: Space.s),
          Wrap(
            spacing: Space.s,
            children: [
              FilledButton(
                onPressed: trainer.resume,
                child: Text(
                  trainer.selection.active
                      ? 'Return to training'
                      : 'Resume lesson',
                ),
              ),
              TextButton(
                onPressed: trainer.leave,
                child: Text(
                  trainer.selection.active ? 'Stop for now' : 'Back to lines',
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _chooseRepertoire(BuildContext context, Trainer trainer) => Padding(
    padding: const EdgeInsets.all(readingCardInset),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          trainer.selection.root.isEmpty
              ? 'Choose your repertoire'
              : 'No training lines available',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: Space.m),
        const Text(
          'Choose a repertoire in the left panel, or import a course PGN. Your progress is saved as you train.',
        ),
        const SizedBox(height: Space.l),
        if (widget.onImport != null)
          FilledButton(
            onPressed: widget.onImport,
            child: const Text('Import course PGN…'),
          ),
      ],
    ),
  );

  Widget _content(BuildContext context) {
    final trainer = widget.trainer;
    if (trainer.lesson case final lesson?) {
      if (lesson.suspended) return _paused(trainer, lesson.line.name);
      return LessonView(
        lesson: lesson,
        onStudy: widget.onStudy,
        trainer: trainer,
        moves: widget.moves,
        onRead: widget.onRead,
      );
    }
    return switch (trainer.state) {
      TrainerIdle() ||
      TrainerLoading() => const _Sentence('Reading training progress…'),
      // The scope stays in reach: a book trains with nothing open.
      TrainerEmpty() when trainer.selection.active => _chooseRepertoire(
        context,
        trainer,
      ),
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
      final TrainerReady ready when trainer.selection.active => TrainingHome(
        trainer: trainer,
        ready: ready,
        onRead: widget.onRead,
        onSettings: widget.onSettings,
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
