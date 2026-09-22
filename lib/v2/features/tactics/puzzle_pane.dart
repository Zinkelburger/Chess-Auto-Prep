import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_run.dart';
import '../../ui/theme.dart';
import 'puzzle_trainer.dart';
import 'puzzle_up.dart';

/// The Puzzle tab of the reading card: whose move it is and what went wrong
/// in the game, what the last move came to, the three buttons in fixed
/// places, the rating once the answer is on view, and how the sitting is
/// going. After the last puzzle it is the sitting's recap instead.
///
/// Nothing on it moves when the feedback changes: each line keeps its
/// height whether it has words in it or not.
class PuzzlePane extends StatelessWidget {
  const PuzzlePane({super.key, required this.trainer});

  final PuzzleTrainer trainer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trainer,
      builder: (context, _) {
        final body = switch ((trainer.up, trainer.recap)) {
          (final PuzzleUp up, _) => _Solving(trainer: trainer, up: up),
          (null, final Recap recap) => _RecapView(
            trainer: trainer,
            recap: recap,
          ),
          (null, null) => const _Idle(),
        };
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            readingCardInset,
            Space.m,
            readingCardInset,
            Space.l,
          ),
          child: body,
        );
      },
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle();

  @override
  Widget build(BuildContext context) => Text(
    'Press Play tactics in the list to start, or pick a puzzle from it.',
    style: Theme.of(context).textTheme.bodySmall,
  );
}

class _Solving extends StatelessWidget {
  const _Solving({required this.trainer, required this.up});

  final PuzzleTrainer trainer;
  final PuzzleUp up;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final puzzle = up.puzzle;
    final side = puzzle.toMove == Side.white ? 'White' : 'Black';
    final moves = puzzle.movesToFind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          moves > 1 ? '$side to play · $moves moves' : '$side to play',
          style: text.titleMedium,
        ),
        const SizedBox(height: Space.xs),
        _GameLine(puzzle: puzzle, finished: up.finished),
        const SizedBox(height: Space.m),
        SizedBox(
          height: feedbackLineHeight,
          child: _FeedbackLine(up: up),
        ),
        const SizedBox(height: Space.s),
        _Buttons(trainer: trainer, up: up),
        const SizedBox(height: Space.m),
        SizedBox(
          height: starRowHeight,
          child: up.finished ? _Stars(trainer: trainer, up: up) : null,
        ),
        _AutoAdvance(trainer: trainer),
        const Divider(height: Space.xl),
        _Progress(trainer: trainer),
      ],
    );
  }
}

/// `You played h5 (inaccuracy)`, and once the answer is on view what it
/// allowed and what it cost: `, allowing Be2  +0.6 → -0.1`.
class _GameLine extends StatelessWidget {
  const _GameLine({required this.puzzle, required this.finished});

  final Puzzle puzzle;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final played = puzzle.played;
    if (played == null) return const SizedBox(height: feedbackLineHeight);
    final note = puzzle.note;
    final refutation = puzzle.refutation;
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'You played '),
          TextSpan(
            text: played,
            style: monoText.copyWith(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: ' (${puzzle.kind.word})'),
          if (finished && refutation != null) ...[
            const TextSpan(text: ', allowing '),
            TextSpan(
              text: refutation,
              style: monoText.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
          if (finished && note != null)
            TextSpan(
              text: '   ${note.before} → ${note.after}',
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// What the last move came to, in words, coloured only where it means
/// something: a wrong move in the error colour, a right one in the accent.
class _FeedbackLine extends StatelessWidget {
  const _FeedbackLine({required this.up});

  final PuzzleUp up;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodyMedium;
    final (words, colour) = switch (up.feedback) {
      null => ('Find the best move.', scheme.onSurfaceVariant),
      Correct(:final found, :final of) => (
        'Correct! ($found/$of)',
        scheme.primary,
      ),
      Incorrect(:final san) => ('Incorrect — $san is not it.', scheme.error),
      Solved() => (
        up.decided == Outcome.failed
            ? 'Solved, after a wrong try.'
            : 'Correct!',
        scheme.primary,
      ),
      Revealed(:final rest) => (
        'Solution: ${rest.join(' ')}',
        scheme.onSurface,
      ),
    };
    final problem = up.saveProblem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          words,
          style: text?.copyWith(color: colour, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        if (problem != null)
          Text(
            'Not saved: $problem',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.error),
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// Show solution, Reset and Skip in the same places whatever happened; Skip
/// reads Next once there is nothing left to find.
class _Buttons extends StatelessWidget {
  const _Buttons({required this.trainer, required this.up});

  final PuzzleTrainer trainer;
  final PuzzleUp up;

  @override
  Widget build(BuildContext context) {
    final atStart = up.found == 0 && up.feedback == null;
    final moved = up.finished || up.decided != null;
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton(
          onPressed: up.finished ? null : trainer.showSolution,
          child: const Tooltip(
            message: 'Show solution (Space)',
            child: Text('Show solution'),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.replay, size: IconSize.action),
          tooltip: 'Try it again from the start',
          onPressed: atStart ? null : trainer.reset,
        ),
        moved
            ? FilledButton(
                onPressed: () => unawaited(trainer.next()),
                child: const Tooltip(
                  message: 'Next puzzle (↓)',
                  child: Text('Next'),
                ),
              )
            : OutlinedButton(
                onPressed: () => unawaited(trainer.next()),
                child: const Tooltip(
                  message: 'Skip this puzzle (↓)',
                  child: Text('Skip'),
                ),
              ),
      ],
    );
  }
}

/// Five stars; one hides the puzzle from training. The star the puzzle
/// already has takes the rating away when clicked again.
class _Stars extends StatelessWidget {
  const _Stars({required this.trainer, required this.up});

  final PuzzleTrainer trainer;
  final PuzzleUp up;

  @override
  Widget build(BuildContext context) {
    final rating = up.rating;
    final text = Theme.of(context).textTheme.labelSmall;
    return Row(
      children: [
        Text('Rate', style: text),
        const SizedBox(width: Space.xs),
        for (var star = 1; star <= 5; star++)
          IconButton(
            icon: Icon(
              star <= rating ? Icons.star : Icons.star_border,
              size: IconSize.action,
            ),
            tooltip: star == 1
                ? 'One star hides it from training'
                : '$star stars',
            onPressed: () => trainer.rate(star == rating ? 0 : star),
            visualDensity: VisualDensity.compact,
          ),
        if (rating == 1) Text('hidden from training', style: text),
      ],
    );
  }
}

class _AutoAdvance extends StatelessWidget {
  const _AutoAdvance({required this.trainer});

  final PuzzleTrainer trainer;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Switch(value: trainer.autoAdvance, onChanged: trainer.setAutoAdvance),
        const SizedBox(width: Space.s),
        const Flexible(
          child: Text(
            'Next puzzle by itself after a solve',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// `Puzzle 3 of 26 · 2 solved · 1 failed`, and the way to stop.
class _Progress extends StatelessWidget {
  const _Progress({required this.trainer});

  final PuzzleTrainer trainer;

  @override
  Widget build(BuildContext context) {
    final run = trainer.run;
    if (run == null) return const SizedBox.shrink();
    final recap = run.recap;
    return Row(
      children: [
        Expanded(
          child: Text(
            [
              'Puzzle ${run.seen.length} of ${run.queue.length}',
              if (recap.solved > 0) '${recap.solved} solved',
              if (recap.failed > 0) '${recap.failed} failed',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(onPressed: trainer.end, child: const Text('End session')),
      ],
    );
  }
}

/// What the sitting came to, and the two ways on.
class _RecapView extends StatelessWidget {
  const _RecapView({required this.trainer, required this.recap});

  final PuzzleTrainer trainer;
  final Recap recap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accuracy = recap.accuracy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Session complete', style: text.titleMedium),
        const SizedBox(height: Space.m),
        Wrap(
          spacing: Space.xl,
          children: [
            _Figure('Solved', recap.solved),
            _Figure('Failed', recap.failed),
            if (recap.skipped > 0) _Figure('Skipped', recap.skipped),
          ],
        ),
        if (accuracy != null) ...[
          const SizedBox(height: Space.m),
          Text(
            'Accuracy ${(accuracy * 100).round()}% · '
            '${formatSeconds(recap.seconds)} total · '
            'avg ${formatSeconds(recap.seconds / recap.attempted)} per puzzle',
            style: text.bodySmall,
          ),
        ],
        const SizedBox(height: Space.l),
        Wrap(
          spacing: Space.s,
          children: [
            if (recap.retry.isNotEmpty)
              FilledButton(
                onPressed: () => unawaited(trainer.retryMistakes()),
                child: Text('Retry mistakes (${recap.retry.length})'),
              ),
            OutlinedButton(
              onPressed: trainer.closeRecap,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: text.titleMedium),
        Text(label, style: text.labelSmall),
      ],
    );
  }
}

/// `4m 12s` from a minute up, `21s` from ten seconds, `4.2s` below that.
String formatSeconds(double seconds) {
  if (seconds >= 60) {
    final whole = seconds.round();
    return '${whole ~/ 60}m ${whole % 60}s';
  }
  return seconds >= 10
      ? '${seconds.round()}s'
      : '${seconds.toStringAsFixed(1)}s';
}
