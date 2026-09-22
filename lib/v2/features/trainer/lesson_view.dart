import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/pgn/move_label.dart';
import '../../chess/training/drill.dart';
import '../../chess/training/schedule.dart';
import '../../ui/theme.dart';
import 'lesson.dart';
import 'trainer.dart';
import 'trainer_words.dart';

/// The Train tab while a sitting runs: the line and how far the sitting has
/// to go, what the lesson wants now, the moves played so far with the note
/// on the last, the one control the moment needs, and the way out.
///
/// Keys: Space goes on, 1–4 rate, ↓ skips the line, Escape leaves.
class LessonView extends StatefulWidget {
  const LessonView({super.key, required this.lesson, required this.trainer});

  final Lesson lesson;
  final Trainer trainer;

  @override
  State<LessonView> createState() => _LessonViewState();
}

class _LessonViewState extends State<LessonView> {
  final _focus = FocusNode(debugLabel: 'lesson');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final lesson = widget.lesson;
    final key = event.logicalKey;
    final rating = _ratingKeys[key];
    if (rating != null) {
      lesson.rate(rating);
    } else if (key == LogicalKeyboardKey.space) {
      lesson.next();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      lesson.skip();
    } else if (key == LogicalKeyboardKey.escape) {
      widget.trainer.leave();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static final _ratingKeys = {
    LogicalKeyboardKey.digit1: Rating.again,
    LogicalKeyboardKey.digit2: Rating.hard,
    LogicalKeyboardKey.digit3: Rating.good,
    LogicalKeyboardKey.digit4: Rating.easy,
  };

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _focus.requestFocus,
        child: ListenableBuilder(
          listenable: widget.lesson,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(
              readingCardInset,
              Space.m,
              readingCardInset,
              Space.s,
            ),
            child: widget.lesson.state is SittingOver
                ? _Over(lesson: widget.lesson, trainer: widget.trainer)
                : _OnLine(lesson: widget.lesson, trainer: widget.trainer),
          ),
        ),
      ),
    );
  }
}

class _OnLine extends StatelessWidget {
  const _OnLine({required this.lesson, required this.trainer});

  final Lesson lesson;
  final Trainer trainer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final drill = lesson.drill;
    final wrong = drill.stage is Missed || drill.stage is Corrected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(lesson: lesson),
        const SizedBox(height: Space.l),
        Text(
          prompt(lesson),
          style: text.titleLarge?.copyWith(
            color: wrong ? Theme.of(context).colorScheme.error : null,
          ),
        ),
        const SizedBox(height: Space.m),
        Expanded(child: _MovesSoFar(drill: drill)),
        if (lesson.unlogged case final failure?)
          Text(
            progressProblem(failure, doing: 'save that answer'),
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        const SizedBox(height: Space.s),
        _Control(lesson: lesson),
        const Divider(height: Space.l),
        _Footer(lesson: lesson, trainer: trainer),
      ],
    );
  }
}

/// The line, its chapter, and how far the sitting has to go.
class _Heading extends StatelessWidget {
  const _Heading({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = lesson.line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line.name, style: text.titleMedium),
        Text(
          '${line.chapter} · ${lesson.learning ? 'Learning' : 'Reviewing'}'
          '${lesson.left > 0 ? ' · ${lesson.left} more after this' : ''}',
          style: text.bodySmall,
        ),
      ],
    );
  }
}

/// The moves on the board, and the note on the last of them: nothing from
/// further down the line, which is what is being asked.
class _MovesSoFar extends StatelessWidget {
  const _MovesSoFar({required this.drill});

  final Drill drill;

  @override
  Widget build(BuildContext context) {
    final moves = drill.line.moves;
    final note = drill.shown == 0 ? null : moves[drill.shown - 1].comment;
    return SingleChildScrollView(
      reverse: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(numberedMoves(moves.take(drill.shown)), style: monoText),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: Space.s),
            Text(note, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// The one control the moment needs: Next while a move is being shown, the
/// ratings when a review is done, the retry when its rating did not save.
class _Control extends StatelessWidget {
  const _Control({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return switch (lesson.state) {
      Drilling() when lesson.drill.stage is Showing => Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: 'Next (Space)',
          child: FilledButton(
            onPressed: lesson.next,
            child: const Text('Next'),
          ),
        ),
      ),
      AwaitingRating() => _Ratings(lesson: lesson),
      SavingLine() => Text('Saving…', style: text.bodySmall),
      LineNotSaved(:final failure) => Row(
        children: [
          Expanded(
            child: Text(
              progressProblem(failure, doing: 'save the rating'),
              style: text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          TextButton(onPressed: lesson.retry, child: const Text('Retry')),
        ],
      ),
      _ => const SizedBox(height: Space.xl),
    };
  }
}

/// How well the user knew the line, each button saying what it schedules.
class _Ratings extends StatelessWidget {
  const _Ratings({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'How well did you know this?',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: Space.s),
      Wrap(
        spacing: Space.s,
        runSpacing: Space.s,
        children: [
          for (final (i, rating) in Rating.values.indexed)
            Tooltip(
              message: '${ratingLabel(rating, lesson.review)} (${i + 1})',
              child: OutlinedButton(
                onPressed: () => lesson.rate(rating),
                child: Text(ratingLabel(rating, lesson.review)),
              ),
            ),
        ],
      ),
    ],
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.lesson, required this.trainer});

  final Lesson lesson;
  final Trainer trainer;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Tooltip(
        message: 'Skip this line (↓)',
        child: TextButton(onPressed: lesson.skip, child: const Text('Skip')),
      ),
      TextButton(onPressed: lesson.restart, child: const Text('Restart line')),
      const Spacer(),
      Tooltip(
        message: 'Back to lines (Esc)',
        child: TextButton(
          onPressed: trainer.leave,
          child: const Text('Back to lines'),
        ),
      ),
    ],
  );
}

/// The sitting is over: what it came to, and the ways on.
class _Over extends StatelessWidget {
  const _Over({required this.lesson, required this.trainer});

  final Lesson lesson;
  final Trainer trainer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tally = lesson.tally;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sittingOver(lesson.kind), style: text.titleMedium),
        const SizedBox(height: Space.s),
        Text(
          '${tally.lines} ${tally.lines == 1 ? 'line' : 'lines'} · '
          '${tally.right} right · ${tally.wrong} wrong',
          style: text.bodySmall,
        ),
        const SizedBox(height: Space.l),
        Wrap(spacing: Space.s, runSpacing: Space.s, children: _ways()),
      ],
    );
  }

  List<Widget> _ways() => [
    FilledButton(onPressed: trainer.leave, child: const Text('Back to lines')),
    if (trainer.dueCount > 0)
      OutlinedButton(
        onPressed: trainer.review,
        child: Text('Review ${trainer.dueCount} more'),
      ),
    if (trainer.untrainedCount > 0)
      OutlinedButton(
        onPressed: trainer.learn,
        child: Text('Learn more · ${trainer.untrainedCount} left'),
      ),
  ];
}
