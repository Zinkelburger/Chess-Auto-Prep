import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/pgn/move_label.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/records.dart';
import '../../chess/training/training_line.dart';
import '../../ui/check_row.dart';
import '../../ui/move_notation.dart';
import '../../ui/relative_time.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import 'trainer.dart';

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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.ready.progress,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.all(readingCardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context),
          const SizedBox(height: Space.s),
          _summary(context),
          const SizedBox(height: Space.l),
          _actions(context),
          const SizedBox(height: Space.m),
          _reviewChoices(),
          CheckRow(
            label: 'Rate difficulty myself',
            value: trainer.options.rateReviews,
            tooltip:
                'Choose Again, Hard, Good or Easy after each line. Your rating sets its next review.',
            onChanged: (on) => trainer.selection.update(
              trainer.options.copyWith(rateReviews: on),
            ),
          ),
          if (trainer.progressProblem case final problem?)
            _problem(context, problem),
          if (trainer.settings?.problem case final problem?)
            _problem(context, problem),
          if (widget.ready.progress.stale)
            _problem(
              context,
              'The repertoire changed. Reload progress before training.',
            ),
          const Divider(height: Space.xl),
          _next(context),
          const SizedBox(height: Space.l),
          _tools(),
          if (_mistakes) ..._mistakeRows(),
        ],
      ),
    ),
  );

  Widget _heading(BuildContext context) {
    final selection = trainer.selection;
    final line = selection.line == null
        ? null
        : widget.ready.lineOf(selection.line!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selection.chapter != null)
          TextButton(
            onPressed: () => selection.select(),
            child: Text(
              '← ${selection.repertoire?.name ?? 'Whole repertoire'}',
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                line?.name ?? selection.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            RowActions(
              tooltip: 'Training actions',
              children: [
                if (widget.onSettings != null)
                  rowAction(
                    'Training settings…',
                    widget.onSettings!,
                    busy: false,
                  ),
                rowAction(
                  'Mark scope as learned',
                  () => unawaited(
                    trainer.changeProgress(
                      widget.ready.progress.mark(
                        trainer.scopeLines,
                        known: true,
                      ),
                    ),
                  ),
                  busy: widget.ready.progress.stale,
                ),
                rowAction(
                  'Mark scope as new',
                  () => unawaited(
                    trainer.changeProgress(
                      widget.ready.progress.mark(
                        trainer.scopeLines,
                        known: false,
                      ),
                    ),
                  ),
                  busy: widget.ready.progress.stale,
                ),
                rowAction(
                  'Reload progress',
                  () => unawaited(trainer.reload()),
                  busy: false,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final progress = widget.ready.progress;
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

  bool get _linePaused {
    final key = trainer.selection.line;
    return key != null &&
        (widget.ready.progress.reviews[key]?.excluded ?? false);
  }

  Widget _actions(BuildContext context) {
    final selection = trainer.selection;
    final paused = selection.scopePaused || _linePaused;
    final busy = widget.ready.progress.stale;
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
              FilledButton(
                onPressed: busy ? null : _resumeScope,
                child: Text(
                  selection.repertoirePaused
                      ? 'Resume repertoire'
                      : 'Resume training',
                ),
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
      final line = widget.ready.lineOf(key);
      if (line != null)
        unawaited(
          trainer.changeProgress(
            widget.ready.progress.setExcluded(line, excluded: false),
          ),
        );
    }
  }

  Widget _reviewChoices() {
    final selection = trainer.selection;
    if (selection.line != null) return const SizedBox.shrink();
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Review'),
        ChoiceChip(
          label: const Text('Due'),
          selected: !trainer.options.reviewAll && !selection.choosing,
          onSelected: (_) {
            selection.chooseLines(false);
            selection.update(trainer.options.copyWith(reviewAll: false));
          },
        ),
        ChoiceChip(
          label: const Text('All learned'),
          selected: trainer.options.reviewAll && !selection.choosing,
          onSelected: (_) {
            selection.chooseLines(false);
            selection.update(trainer.options.copyWith(reviewAll: true));
          },
        ),
        FilterChip(
          label: Text(
            selection.choosing
                ? '${selection.picked.length} selected'
                : 'Choose lines',
          ),
          selected: selection.choosing,
          onSelected: selection.chooseLines,
        ),
      ],
    );
  }

  Widget _next(BuildContext context) {
    final selection = trainer.selection;
    final lines = toLearn(
      trainer.availableLines,
      widget.ready.progress.reviews,
      widget.ready.progress.now,
    );
    final line = selection.line == null
        ? lines.firstOrNull
        : widget.ready.lineOf(selection.line!);
    if (line == null)
      return Text(
        selection.choosing
            ? 'Select lines in the outline to learn or review.'
            : trainer.scopeLines.isEmpty
            ? 'No trainable lines in this scope.'
            : 'No new lines in this scope. Review learned lines or choose another chapter.',
        style: Theme.of(context).textTheme.bodySmall,
      );
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
          onPressed: () =>
              widget.onRead(widget.ready.toRead(line, ReadIn.moves)),
          child: const Text('Read moves and notes'),
        ),
        if (selection.line != null) _learned(line),
      ],
    );
  }

  Widget _learned(TrainingLine line) => CheckRow(
    label: 'Learned',
    value: !widget.ready.progress.reviewOf(line).untrained,
    onChanged: widget.ready.progress.stale
        ? null
        : (on) => unawaited(
            trainer.changeProgress(
              widget.ready.progress.mark([line], known: on),
            ),
          ),
  );

  Widget _tools() {
    final selection = trainer.selection;
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      children: [
        TextButton(
          onPressed: () => setState(() => _mistakes = !_mistakes),
          child: Text(
            _mistakes
                ? 'Hide mistakes'
                : 'Mistakes · ${_scopedMistakes.length}',
          ),
        ),
        if (!selection.scopePaused && !_linePaused)
          TextButton(
            onPressed: () {
              final key = selection.line;
              final line = key == null ? null : widget.ready.lineOf(key);
              if (line != null) {
                unawaited(
                  trainer.changeProgress(
                    widget.ready.progress.setExcluded(line, excluded: true),
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

  // Existing mistake records remain accessible without occupying the home.
  List<Attempt> get _scopedMistakes {
    final keys = trainer.scopeLines.map((l) => l.key).toSet();
    return widget.ready.progress.mistakes
        .where((m) => keys.contains(m.key))
        .toList();
  }

  List<Widget> _mistakeRows() => [
    for (final mistake in _scopedMistakes)
      ListTile(
        dense: true,
        title: Text('Played ${mistake.played} · expected ${mistake.expected}'),
        subtitle: Text(relativeTime(mistake.at.toLocal())),
        onTap: () {
          final line = widget.ready.lineOf(mistake.key);
          if (line != null)
            widget.onRead(
              widget.ready.toRead(line, ReadIn.board, ply: mistake.ply),
            );
        },
      ),
  ];

  Widget _problem(BuildContext context, String text) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
  );
}
