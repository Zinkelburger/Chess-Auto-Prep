import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/pgn/move_label.dart';
import '../../chess/training/records.dart';
import '../../chess/training/sitting.dart';
import '../../chess/training/training_line.dart';
import '../../storage/training_store.dart';
import '../../ui/relative_time.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'progress.dart';
import 'trainer.dart';
import 'trainer_words.dart';

/// The trainer between sittings: the scope, where its lines stand, Review
/// and Learn, and the lines themselves — or the wrong answers given in
/// them — searchable.
class LineList extends StatefulWidget {
  const LineList({super.key, required this.trainer, required this.ready});

  final Trainer trainer;
  final TrainerReady ready;

  @override
  State<LineList> createState() => _LineListState();
}

enum _Showing { lines, mistakes }

class _LineListState extends State<LineList> {
  final _search = TextEditingController();
  var _query = '';
  var _showing = _Showing.lines;

  /// What the last change by hand could not write, until the next one.
  String? _problem;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _change(
    Future<ProgressWrite> write, {
    required String doing,
  }) async {
    final result = await write;
    if (!mounted) return;
    setState(
      () => _problem = result is ProgressWritten
          ? null
          : progressProblem(result, doing: doing),
    );
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.ready.progress;
    return ListenableBuilder(
      listenable: progress,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(
          readingCardInset,
          Space.s,
          readingCardInset,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              trainer: widget.trainer,
              ready: widget.ready,
              onChange: (write, doing) =>
                  unawaited(_change(write, doing: doing)),
            ),
            if (progress.stale)
              _Problem(
                progressProblem(
                  const ProgressConflict(),
                  doing: 'save training progress',
                ),
                action: ('Reload', () => unawaited(widget.trainer.reload())),
              )
            else if (_problem case final problem?)
              _Problem(problem),
            const SizedBox(height: Space.m),
            _toolbar(progress),
            const SizedBox(height: Space.s),
            Expanded(
              child: _showing == _Showing.lines
                  ? _lines(progress)
                  : _mistakes(progress),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(TrainingProgress progress) => Row(
    children: [
      SegmentedButton<_Showing>(
        segments: [
          const ButtonSegment(value: _Showing.lines, label: Text('Lines')),
          ButtonSegment(
            value: _Showing.mistakes,
            label: Text('Mistakes · ${progress.mistakes.length}'),
          ),
        ],
        selected: {_showing},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _showing = s.single),
      ),
      const SizedBox(width: Space.m),
      Expanded(
        child: SearchField(
          controller: _search,
          hint: _showing == _Showing.lines ? 'Search lines' : 'Search mistakes',
          onChanged: (text) => setState(() => _query = text.toLowerCase()),
        ),
      ),
    ],
  );

  Widget _lines(TrainingProgress progress) {
    final lines = [
      for (final line in widget.ready.lines)
        if (_query.isEmpty || _searchText(line).contains(_query)) line,
    ];
    if (lines.isEmpty) {
      return _Muted(_query.isEmpty ? 'No lines here yet.' : 'No line matches.');
    }
    final many = widget.ready.chapters.length > 1;
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) => _LineRow(
        line: lines[index],
        progress: progress,
        showChapter: many,
        onTrain: () => widget.trainer.trainLine(lines[index]),
        onChange: (write, doing) => unawaited(_change(write, doing: doing)),
      ),
    );
  }

  Widget _mistakes(TrainingProgress progress) {
    final names = {for (final l in widget.ready.lines) l.key: l.name};
    final rows = [
      for (final m in progress.mistakes)
        if (_query.isEmpty ||
            '${names[m.key] ?? ''} ${m.played} ${m.expected}'
                .toLowerCase()
                .contains(_query))
          m,
    ];
    if (rows.isEmpty) return const _Muted('No recorded mistakes.');
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) =>
          _MistakeRow(mistake: rows[index], line: names[rows[index].key]),
    );
  }

  static String _searchText(TrainingLine line) =>
      '${line.name} ${line.chapter} '
              '${[for (final m in line.moves) m.san].join(' ')}'
          .toLowerCase();
}

/// The scope, the counts, and the two ways into a sitting.
class _Header extends StatelessWidget {
  const _Header({
    required this.trainer,
    required this.ready,
    required this.onChange,
  });

  final Trainer trainer;
  final TrainerReady ready;
  final void Function(Future<ProgressWrite> write, String doing) onChange;

  @override
  Widget build(BuildContext context) {
    final progress = ready.progress;
    final lines = ready.lines;
    final counts = countsOf(lines, progress.reviews, progress.now);
    final due = counts[LineStatus.due]!;
    final untrained = counts[LineStatus.untrained]!;
    final learn = untrained < learnSitting ? untrained : learnSitting;
    final muted = Theme.of(context).textTheme.bodySmall;
    final busy = progress.stale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SegmentedButton<TrainScope>(
              segments: const [
                ButtonSegment(
                  value: TrainScope.chapter,
                  label: Text('This chapter'),
                ),
                ButtonSegment(
                  value: TrainScope.repertoire,
                  label: Text('Whole repertoire'),
                ),
              ],
              selected: {trainer.scope},
              showSelectedIcon: false,
              onSelectionChanged: (s) => trainer.setScope(s.single),
            ),
            const Spacer(),
            RowActions(
              tooltip: 'Training actions',
              children: [
                rowAction(
                  'Mark every line known',
                  () => onChange(
                    progress.mark(lines, known: true),
                    'save training progress',
                  ),
                  busy: busy,
                ),
                rowAction(
                  'Mark every line untrained',
                  () => onChange(
                    progress.mark(lines, known: false),
                    'save training progress',
                  ),
                  busy: busy,
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
        const SizedBox(height: Space.s),
        Text(
          '${counts[LineStatus.learned]} learned · $due due · '
          '$untrained untrained'
          '${counts[LineStatus.excluded]! > 0 ? ' · ${counts[LineStatus.excluded]} excluded' : ''}',
          style: muted,
        ),
        const SizedBox(height: Space.s),
        Row(
          children: [
            FilledButton(
              onPressed: due == 0 || busy ? null : trainer.review,
              child: Text(due == 0 ? 'Nothing due' : 'Review $due'),
            ),
            const SizedBox(width: Space.s),
            OutlinedButton(
              onPressed: learn == 0 || busy ? null : trainer.learn,
              child: Text(
                learn == 0 ? 'Nothing left to learn' : 'Learn $learn',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.progress,
    required this.showChapter,
    required this.onTrain,
    required this.onChange,
  });

  final TrainingLine line;
  final TrainingProgress progress;
  final bool showChapter;
  final VoidCallback onTrain;
  final void Function(Future<ProgressWrite> write, String doing) onChange;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = progress.status(line);
    final review = progress.reviews[line.key];
    final trained = status == LineStatus.due || status == LineStatus.learned;
    final moves = numberedMoves(line.moves);
    return InkWell(
      onTap: status == LineStatus.game ? null : onTrain,
      child: SizedBox(
        height: trainRowHeight,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    showChapter ? '${line.chapter} · $moves' : moves,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.s),
            Text(
              statusWord(status, review, progress.now),
              style: status == LineStatus.due
                  ? text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : text.bodySmall,
            ),
            if (status != LineStatus.game)
              RowActions(
                children: [
                  rowAction('Train this line', onTrain, busy: false),
                  if (trained)
                    rowAction(
                      'Forget this line',
                      () => onChange(
                        progress.mark([line], known: false),
                        'save training progress',
                      ),
                      busy: progress.stale,
                    )
                  else if (status == LineStatus.untrained)
                    rowAction(
                      'I know this line',
                      () => onChange(
                        progress.mark([line], known: true),
                        'save training progress',
                      ),
                      busy: progress.stale,
                    ),
                  rowAction(
                    status == LineStatus.excluded
                        ? 'Include in training'
                        : 'Exclude from training',
                    () => onChange(
                      progress.setExcluded(
                        line,
                        excluded: status != LineStatus.excluded,
                      ),
                      'save training progress',
                    ),
                    busy: progress.stale,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow({required this.mistake, required this.line});

  final Attempt mistake;
  final String? line;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final number = _number(mistake);
    return SizedBox(
      height: trainRowHeight,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Book: $number${mistake.expected}  ·  '
                  'You: $number${mistake.played}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  line ?? 'A line no longer in this scope',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          Text(relativeTime(mistake.at.toLocal()), style: text.bodySmall),
        ],
      ),
    );
  }

  /// `12.` or `12...`, from the position the move was asked in.
  static String _number(Attempt mistake) => mistake.fen.whiteToMove
      ? '${mistake.fen.fullMove}.'
      : '${mistake.fen.fullMove}...';
}

class _Problem extends StatelessWidget {
  const _Problem(this.sentence, {this.action});

  final String sentence;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              sentence,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: error),
            ),
          ),
          if (action case (final label, final run))
            TextButton(onPressed: run, child: Text(label)),
        ],
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.m),
    child: Text(words, style: Theme.of(context).textTheme.bodySmall),
  );
}
