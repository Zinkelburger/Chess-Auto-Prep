import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_run.dart';
import '../../ui/theme.dart';
import 'puzzle_trainer.dart';
import '../../ui/app_action.dart';

/// The Puzzle tab of the reading card: whose move it is and what went wrong
/// in the game, what the last move came to, the three buttons in fixed
/// places, the rating once the answer is on view, and how the sitting is
/// going. After the last puzzle it is the sitting's recap instead.
///
/// Nothing on it moves when the feedback changes: each line keeps its
/// height whether it has words in it or not.
class PuzzlePane extends StatelessWidget {
  const PuzzlePane({super.key, required this.trainer, this.onAnalyze});

  final PuzzleTrainer trainer;

  /// Opens the puzzle's game with the engine on, once the answer is on
  /// view: the host owns the tabs and the engine.
  final VoidCallback? onAnalyze;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trainer,
      builder: (context, _) {
        final body = switch ((trainer.up, trainer.recap)) {
          (final PuzzleUp up, _) => _Solving(
            trainer: trainer,
            up: up,
            onAnalyze: onAnalyze,
          ),
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
    'Press Play in the list to start, or click a puzzle in it.',
    style: Theme.of(context).textTheme.bodyMedium,
  );
}

class _Solving extends StatelessWidget {
  const _Solving({
    required this.trainer,
    required this.up,
    required this.onAnalyze,
  });

  final PuzzleTrainer trainer;
  final PuzzleUp up;
  final VoidCallback? onAnalyze;

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
        Text(
          [
            if (puzzle.opponent.isNotEmpty) 'vs ${puzzle.opponent}',
            if (puzzle.date.isNotEmpty) puzzle.date,
          ].join(' · '),
          style: text.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: Space.m),
        _GameLine(puzzle: puzzle, finished: up.finished),
        const SizedBox(height: Space.m),
        SizedBox(
          height: feedbackLineHeight,
          child: _FeedbackLine(up: up),
        ),
        const SizedBox(height: Space.s),
        _Buttons(trainer: trainer, up: up, onAnalyze: onAnalyze),
        const SizedBox(height: Space.m),
        SizedBox(
          height: starRowHeight,
          child: up.finished ? _Stars(trainer: trainer, up: up) : null,
        ),
        const Divider(height: Space.xl),
        _Progress(trainer: trainer),
        _AutoAdvance(trainer: trainer),
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
      null => ('Find the best move.', scheme.onSurface),
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
/// reads Next once the attempt is scored, and becomes the filled button:
/// the thing to do now. Analyze takes Show solution's place once the answer
/// is on view.
class _Buttons extends StatelessWidget {
  const _Buttons({
    required this.trainer,
    required this.up,
    required this.onAnalyze,
  });

  final PuzzleTrainer trainer;
  final PuzzleUp up;
  final VoidCallback? onAnalyze;

  @override
  Widget build(BuildContext context) {
    final atStart = up.found == 0 && up.feedback == null;
    final moved = up.finished || up.decided != null;
    void next() => unawaited(trainer.next());
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (up.finished)
          _button(
            'Analyze',
            Icons.insights,
            onAnalyze,
            tip: 'Open the game with the engine on',
          )
        else
          _button(
            'Show solution',
            Icons.lightbulb_outline,
            trainer.showSolution,
            tip: withKey('Show solution', 'Space'),
          ),
        IconButton(
          icon: const Icon(Icons.replay, size: IconSize.action),
          tooltip: 'Try it again from the start',
          onPressed: atStart ? null : trainer.reset,
        ),
        if (moved)
          _button(
            'Next',
            Icons.arrow_forward,
            next,
            tip: withKey('Next puzzle', '↓'),
            filled: true,
            iconAfter: true,
          )
        else
          _button(
            'Skip',
            Icons.skip_next,
            next,
            tip: withKey('Skip this puzzle', '↓'),
            iconAfter: true,
          ),
      ],
    );
  }

  /// A labelled button with its icon; the secondary style unless [filled].
  static Widget _button(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    required String tip,
    bool filled = false,
    bool iconAfter = false,
  }) => Tooltip(
    message: tip,
    child: FilledButton.icon(
      style: filled ? null : secondaryButtonStyle,
      onPressed: onPressed,
      icon: Icon(icon, size: IconSize.action),
      iconAlignment: iconAfter ? IconAlignment.end : IconAlignment.start,
      label: Text(label),
    ),
  );
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

/// A small tick under the progress line: a setting, not a thing to do.
class _AutoAdvance extends StatelessWidget {
  const _AutoAdvance({required this.trainer});

  final PuzzleTrainer trainer;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value: trainer.autoAdvance,
          onChanged: (on) => trainer.setAutoAdvance(on ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Flexible(
          child: Text(
            'Go to the next puzzle after a solve',
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// `‹  Puzzle 3 of 26 · 2 solved · 1 failed`, and the way to stop.
class _Progress extends StatelessWidget {
  const _Progress({required this.trainer});

  final PuzzleTrainer trainer;

  @override
  Widget build(BuildContext context) {
    final run = trainer.run;
    if (run == null) return const SizedBox.shrink();
    final recap = run.recap;
    final current = trainer.up?.puzzle.fen;
    final at = current == null
        ? run.seen.length
        : run.seen.indexOf(current) + 1;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, size: IconSize.action),
          tooltip: withKey('Previous puzzle', '↑'),
          onPressed: trainer.hasPrevious
              ? () => unawaited(trainer.previous())
              : null,
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: Text(
            [
              'Puzzle $at of ${run.queue.length}',
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
            FilledButton(
              style: secondaryButtonStyle,
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
