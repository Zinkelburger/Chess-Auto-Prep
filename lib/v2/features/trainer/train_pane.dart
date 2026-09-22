import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'lesson_view.dart';
import 'line_list.dart';
import 'trainer.dart';
import 'trainer_words.dart';

/// The Train tab of the reading card: the lines of the chapter, or of its
/// repertoire, with where each stands and the two ways in — Review what is
/// due, Learn what is new — or, while a sitting runs, the lesson.
class TrainPane extends StatefulWidget {
  const TrainPane({super.key, required this.trainer});

  final Trainer trainer;

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
      builder: (context, _) {
        final trainer = widget.trainer;
        if (trainer.lesson case final lesson?) {
          return LessonView(lesson: lesson, trainer: trainer);
        }
        return switch (trainer.state) {
          TrainerIdle() ||
          TrainerLoading() => const _Sentence('Reading training progress…'),
          TrainerEmpty(:final why) => _Sentence(emptyReason(why)),
          TrainerFailed(:final failure) => _Failed(
            sentence: progressProblem(
              failure,
              doing: 'read the training progress',
            ),
            onRetry: trainer.reload,
          ),
          final TrainerReady ready => LineList(trainer: trainer, ready: ready),
        };
      },
    );
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
