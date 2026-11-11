import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/pgn/move_label.dart';
import '../../chess/training/records.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../ui/app_icons.dart';
import '../../ui/check_row.dart';
import '../../ui/move_notation.dart';
import '../../ui/problem_line.dart';
import '../../ui/relative_time.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import '../../ui/toggle_chip.dart';
import '../../ui/tool_button.dart';
import 'trainer.dart';
import 'trainer_state.dart';

/// The selected scope's training desk, inside the shared Train pane.
class TrainingHome extends StatefulWidget {
  const TrainingHome({
    super.key,
    required this.trainer,
    required this.ready,
    required this.onRead,
    this.onSettings,
  });
  final Trainer trainer;
  final TrainerReady ready;
  final ValueChanged<LineToRead> onRead;
  final VoidCallback? onSettings;

  @override
  State<TrainingHome> createState() => _TrainingHomeState();
}

class _TrainingHomeState extends State<TrainingHome> {
  bool _mistakes = false;
  Trainer get trainer => widget.trainer;
  TrainerReady get ready => widget.ready;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ready.progress,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.all(readingCardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Heading(
            trainer: trainer,
            ready: ready,
            onSettings: widget.onSettings,
          ),
          const SizedBox(height: Space.s),
          _Summary(trainer: trainer, ready: ready),
          const SizedBox(height: Space.l),
          _Actions(trainer: trainer, ready: ready),
          const SizedBox(height: Space.m),
          _ReviewChoices(trainer: trainer),
          CheckRow(
            label: 'Rate difficulty myself',
            value: trainer.options.rateReviews,
            tooltip:
                'Choose Again, Hard, Good or Easy after each line. Your rating sets its next review.',
            onChanged: (on) => trainer.selection.update(
              trainer.options.copyWith(rateReviews: on),
            ),
          ),
          if (trainer.progressProblem case final problem?) ProblemLine(problem),
          if (trainer.settings?.problem case final problem?)
            ProblemLine(problem),
          if (ready.progress.stale)
            const ProblemLine(
              'The repertoire changed. Reload progress before training.',
            ),
          const Divider(height: Space.xl),
          _Next(trainer: trainer, ready: ready, onRead: widget.onRead),
          const SizedBox(height: Space.l),
          _Tools(
            trainer: trainer,
            ready: ready,
            mistakes: _mistakes,
            onToggleMistakes: () => setState(() => _mistakes = !_mistakes),
          ),
          if (_mistakes)
            for (final mistake in _scopedMistakes(trainer, ready))
              _MistakeRow(
                ready: ready,
                mistake: mistake,
                onRead: widget.onRead,
              ),
        ],
      ),
    ),
  );
}

bool _linePaused(Trainer trainer, TrainerReady ready) {
  final key = trainer.selection.line;
  return key != null && (ready.progress.reviews[key]?.excluded ?? false);
}

// Existing mistake records remain accessible without occupying the home.
List<Attempt> _scopedMistakes(Trainer trainer, TrainerReady ready) {
  final keys = trainer.scopeLines.map((l) => l.key).toSet();
  return ready.progress.mistakes.where((m) => keys.contains(m.key)).toList();
}

class _Heading extends StatelessWidget {
  const _Heading({
    required this.trainer,
    required this.ready,
    required this.onSettings,
  });

  final Trainer trainer;
  final TrainerReady ready;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final selection = trainer.selection;
    final line = selection.line == null ? null : ready.lineOf(selection.line!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (selection.chapter != null)
              ToolButton(
                icon: AppIcons.back,
                tooltip:
                    'Back to ${selection.repertoire?.name ?? 'the whole repertoire'}',
                onPressed: () => selection.select(),
              ),
            Expanded(
              child: Text(
                line?.name ?? selection.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            RowActions(
              tooltip: 'Training actions',
              children: [
                if (onSettings != null)
                  rowAction(
                    'Training settings…',
                    onSettings!,
                    icon: AppIcons.settings,
                  ),
                rowAction(
                  'Mark scope as learned',
                  () => unawaited(
                    trainer.changeProgress(
                      ready.progress.mark(trainer.scopeLines, known: true),
                    ),
                  ),
                  busy: ready.progress.stale,
                ),
                rowAction(
                  'Mark scope as new',
                  () => unawaited(
                    trainer.changeProgress(
                      ready.progress.mark(trainer.scopeLines, known: false),
                    ),
                  ),
                  busy: ready.progress.stale,
                ),
                rowAction('Reload progress', () => unawaited(trainer.reload())),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.trainer, required this.ready});

  final Trainer trainer;
  final TrainerReady ready;

  @override
  Widget build(BuildContext context) {
    final progress = ready.progress;
    final lines = trainer.scopeLines
        .where((l) => !l.modelGame && l.yourMoves > 0)
        .toList();
    final learned = lines.where((l) => !progress.reviewOf(l).untrained).length;
    final due = lines
        .where(
          (l) =>
              !progress.reviewOf(l).excluded &&
              progress.reviewOf(l).dueAt(progress.now),
        )
        .length;
    return Text(
      '$learned of ${lines.length} learned · $due due',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.trainer, required this.ready});

  final Trainer trainer;
  final TrainerReady ready;

  @override
  Widget build(BuildContext context) {
    final selection = trainer.selection;
    final paused = selection.scopePaused || _linePaused(trainer, ready);
    final busy = ready.progress.stale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (paused) ...[
          Text(
            selection.repertoirePaused
                ? 'This repertoire is paused.'
                : 'Training is paused for this ${selection.line == null ? 'chapter' : 'line'}.',
          ),
          const SizedBox(height: Space.s),
        ],
        Wrap(
          spacing: Space.m,
          runSpacing: Space.s,
          children: [
            if (paused)
              FilledButton.icon(
                onPressed: busy ? null : _resumeScope,
                icon: const Icon(AppIcons.run, size: IconSize.action),
                label: const Text('Resume'),
              )
            else
              FilledButton(
                onPressed: trainer.learnCount == 0 || busy
                    ? null
                    : trainer.learn,
                child: Text(
                  selection.line == null ? 'Learn' : 'Learn this line',
                ),
              ),
            OutlinedButton(
              onPressed: trainer.reviewCount == 0 || busy
                  ? null
                  : trainer.review,
              child: Text(
                selection.line == null ? 'Review' : 'Review this line',
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s),
        Text(
          paused
              ? 'Your progress is kept.'
              : '${trainer.learnCount} new to learn · ${trainer.reviewCount} to review',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  void _resumeScope() {
    final selection = trainer.selection;
    if (selection.repertoirePaused) {
      selection.pauseScope(false);
    } else if (selection.scopePaused) {
      selection.pauseScope(false, chapter: selection.chapter);
    } else if (selection.line case final key?) {
      final line = ready.lineOf(key);
      if (line != null) {
        unawaited(
          trainer.changeProgress(
            ready.progress.setExcluded(line, excluded: false),
          ),
        );
      }
    }
  }
}

class _ReviewChoices extends StatelessWidget {
  const _ReviewChoices({required this.trainer});

  final Trainer trainer;

  @override
  Widget build(BuildContext context) {
    final selection = trainer.selection;
    if (selection.line != null) return const SizedBox.shrink();
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Review'),
        ToggleChip(
          label: 'Due',
          selected: !trainer.options.reviewAll && !selection.choosing,
          onSelected: (_) {
            selection.chooseLines(false);
            selection.update(trainer.options.copyWith(reviewAll: false));
          },
        ),
        ToggleChip(
          label: 'All learned',
          selected: trainer.options.reviewAll && !selection.choosing,
          onSelected: (_) {
            selection.chooseLines(false);
            selection.update(trainer.options.copyWith(reviewAll: true));
          },
        ),
        ToggleChip(
          label: selection.choosing
              ? '${selection.picked.length} selected'
              : 'Choose lines',
          selected: selection.choosing,
          onSelected: selection.chooseLines,
        ),
      ],
    );
  }
}

class _Next extends StatelessWidget {
  const _Next({
    required this.trainer,
    required this.ready,
    required this.onRead,
  });

  final Trainer trainer;
  final TrainerReady ready;
  final ValueChanged<LineToRead> onRead;

  @override
  Widget build(BuildContext context) {
    final selection = trainer.selection;
    final lines = toLearn(
      trainer.availableLines,
      ready.progress.reviews,
      ready.progress.now,
    );
    final line = selection.line == null
        ? lines.firstOrNull
        : ready.lineOf(selection.line!);
    if (line == null) {
      return Text(
        selection.choosing
            ? 'Select lines in the outline to learn or review.'
            : trainer.scopeLines.isEmpty
            ? 'No trainable lines in this scope.'
            : 'No new lines in this scope. Review learned lines or choose another chapter.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          selection.line == null ? 'Next to learn' : line.chapter,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: Space.s),
        Text(line.name, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Space.s),
        Text(displaySan(context, numberedMoves(line.moves)), style: monoText),
        const SizedBox(height: Space.s),
        TextButton(
          onPressed: () => onRead(ready.toRead(line, ReadIn.moves)),
          child: const Text('Read moves and notes'),
        ),
        if (selection.line != null)
          _Learned(trainer: trainer, ready: ready, line: line),
      ],
    );
  }
}

class _Learned extends StatelessWidget {
  const _Learned({
    required this.trainer,
    required this.ready,
    required this.line,
  });

  final Trainer trainer;
  final TrainerReady ready;
  final TrainingLine line;

  @override
  Widget build(BuildContext context) => CheckRow(
    label: 'Learned',
    value: !ready.progress.reviewOf(line).untrained,
    onChanged: ready.progress.stale
        ? null
        : (on) => unawaited(
            trainer.changeProgress(ready.progress.mark([line], known: on)),
          ),
  );
}

class _Tools extends StatelessWidget {
  const _Tools({
    required this.trainer,
    required this.ready,
    required this.mistakes,
    required this.onToggleMistakes,
  });

  final Trainer trainer;
  final TrainerReady ready;
  final bool mistakes;
  final VoidCallback onToggleMistakes;

  @override
  Widget build(BuildContext context) {
    final selection = trainer.selection;
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      children: [
        TextButton(
          onPressed: onToggleMistakes,
          child: Text(
            mistakes
                ? 'Hide mistakes'
                : 'Mistakes · ${_scopedMistakes(trainer, ready).length}',
          ),
        ),
        if (!selection.scopePaused && !_linePaused(trainer, ready))
          TextButton(
            onPressed: () {
              final key = selection.line;
              final line = key == null ? null : ready.lineOf(key);
              if (line != null) {
                unawaited(
                  trainer.changeProgress(
                    ready.progress.setExcluded(line, excluded: true),
                  ),
                );
              } else {
                selection.pauseScope(true, chapter: selection.chapter);
              }
            },
            child: Text(
              'Pause ${selection.line != null
                  ? 'line'
                  : selection.chapter != null
                  ? 'chapter'
                  : 'repertoire'} training',
            ),
          ),
      ],
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow({
    required this.ready,
    required this.mistake,
    required this.onRead,
  });

  final TrainerReady ready;
  final Attempt mistake;
  final ValueChanged<LineToRead> onRead;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text('Played ${mistake.played} · expected ${mistake.expected}'),
    subtitle: Text(relativeTime(mistake.at.toLocal())),
    onTap: () {
      final line = ready.lineOf(mistake.key);
      if (line != null) {
        onRead(ready.toRead(line, ReadIn.board, ply: mistake.ply));
      }
    },
  );
}
