import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/pgn/move_label.dart';
import '../../chess/training/line_order.dart';
import '../../chess/training/records.dart';
import '../../chess/training/schedule.dart';
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
/// them — searchable. A line can be sent to be read ([onRead]); a mistake
/// sends the board to the position it was made in.
class LineList extends StatefulWidget {
  const LineList({
    super.key,
    required this.trainer,
    required this.ready,
    required this.onRead,
    required this.offerBuilder,
  });

  final Trainer trainer;
  final TrainerReady ready;
  final ValueChanged<LineToRead> onRead;

  /// Whether a row offers `Open in Builder`: not while the builder is the
  /// mode, where reading the line is the same thing.
  final bool offerBuilder;

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
            if (_showing == _Showing.lines && _orders.length > 1) ...[
              const SizedBox(height: Space.s),
              _orderPicker(),
            ],
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

  /// The orders the lines can be put in: the likeliest first only when the
  /// file says how likely they are.
  List<LineOrder> get _orders => [
    for (final order in LineOrder.values)
      if (canOrder(widget.ready.lines, order)) order,
  ];

  Widget _orderPicker() => Align(
    alignment: Alignment.centerLeft,
    child: SegmentedButton<LineOrder>(
      segments: [
        for (final order in _orders)
          ButtonSegment(value: order, label: Text(orderName(order))),
      ],
      selected: {
        _orders.contains(widget.trainer.order)
            ? widget.trainer.order
            : LineOrder.training,
      },
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelectionChanged: (s) => widget.trainer.order = s.single,
    ),
  );

  Widget _lines(TrainingProgress progress) {
    final order = canOrder(widget.ready.lines, widget.trainer.order)
        ? widget.trainer.order
        : LineOrder.training;
    final all = ordered(
      widget.ready.lines,
      order,
      reviews: progress.reviews,
      now: progress.now,
    );
    final lines = [
      for (final line in all)
        if (_query.isEmpty || _searchText(line).contains(_query)) line,
    ];
    if (lines.isEmpty) {
      return _Muted(_query.isEmpty ? 'No lines here yet.' : 'No line matches.');
    }
    final many = widget.ready.chapters.length > 1;
    final departs = _departures(all);
    void read(TrainingLine line, ReadIn place) =>
        widget.onRead(widget.ready.toRead(line, place));
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) => _LineRow(
        line: lines[index],
        departs: departs[lines[index].key] ?? 0,
        progress: progress,
        showChapter: many,
        offerBuilder: widget.offerBuilder,
        onTrain: () => widget.trainer.trainLine(lines[index]),
        onRead: (place) => read(lines[index], place),
        onChange: (write, doing) => unawaited(_change(write, doing: doing)),
      ),
    );
  }

  Widget _mistakes(TrainingProgress progress) {
    final ready = widget.ready;
    final rows = [
      for (final m in progress.mistakes)
        if (_query.isEmpty ||
            '${ready.lineOf(m.key)?.name ?? ''} ${m.played} ${m.expected}'
                .toLowerCase()
                .contains(_query))
          m,
    ];
    if (rows.isEmpty) return const _Muted('No recorded mistakes.');
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final mistake = rows[index];
        final line = ready.lineOf(mistake.key);
        return _MistakeRow(
          mistake: mistake,
          line: line?.name,
          // The position the move was asked in, on the board; the list
          // stays, so the next mistake is one click away.
          onShow: line == null || mistake.ply > line.moves.length
              ? null
              : () => widget.onRead(
                  ready.toRead(line, ReadIn.board, ply: mistake.ply),
                ),
        );
      },
    );
  }

  /// For each line, how many of its first moves the line above it in its
  /// chapter plays too: a row shows its line from where it leaves, since
  /// lines of one chapter mostly share their opening. [lines] is the list
  /// in the order it is shown.
  static Map<LineKey, int> _departures(List<TrainingLine> lines) {
    final shared = <LineKey, int>{};
    for (var i = 1; i < lines.length; i++) {
      final (above, line) = (lines[i - 1], lines[i]);
      if (above.key.source != line.key.source) continue;
      var n = 0;
      while (n < above.moves.length &&
          n < line.moves.length &&
          above.moves[n].san == line.moves[n].san) {
        n++;
      }
      shared[line.key] = n == line.moves.length ? 0 : n;
    }
    return shared;
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
    final counts = countsOf(ready.lines, progress.reviews, progress.now);
    final due = counts[LineStatus.due]!;
    final untrained = counts[LineStatus.untrained]!;
    final learn = untrained < learnSitting ? untrained : learnSitting;
    final excluded = counts[LineStatus.excluded]!;
    final busy = progress.stale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [_scope(), const Spacer(), _actions(progress)]),
        const SizedBox(height: Space.s),
        Text(
          '${counts[LineStatus.learned]} learned · $due due · '
          '$untrained untrained'
          '${excluded > 0 ? ' · $excluded excluded' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
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

  Widget _scope() => SegmentedButton<TrainScope>(
    segments: const [
      ButtonSegment(value: TrainScope.chapter, label: Text('This chapter')),
      ButtonSegment(
        value: TrainScope.repertoire,
        label: Text('Whole repertoire'),
      ),
    ],
    selected: {trainer.scope},
    showSelectedIcon: false,
    onSelectionChanged: (s) => trainer.setScope(s.single),
  );

  Widget _actions(TrainingProgress progress) => RowActions(
    tooltip: 'Training actions',
    children: [
      rowAction(
        'Mark every line known',
        () => onChange(
          progress.mark(ready.lines, known: true),
          'save training progress',
        ),
        busy: progress.stale,
      ),
      rowAction(
        'Mark every line untrained',
        () => onChange(
          progress.mark(ready.lines, known: false),
          'save training progress',
        ),
        busy: progress.stale,
      ),
      rowAction(
        'Reload progress',
        () => unawaited(trainer.reload()),
        busy: false,
      ),
    ],
  );
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.departs,
    required this.progress,
    required this.showChapter,
    required this.offerBuilder,
    required this.onTrain,
    required this.onRead,
    required this.onChange,
  });

  final TrainingLine line;

  /// How many of the line's first moves the row leaves out.
  final int departs;
  final TrainingProgress progress;
  final bool showChapter;
  final bool offerBuilder;
  final VoidCallback onTrain;
  final ValueChanged<ReadIn> onRead;
  final void Function(Future<ProgressWrite> write, String doing) onChange;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = progress.status(line);
    final review = progress.reviews[line.key];
    final moves = departs == 0
        ? numberedMoves(line.moves)
        : '…${numberedMoves(line.moves.skip(departs))}';
    return InkWell(
      // A game is there to be read; a line, to be trained.
      onTap: status == LineStatus.game ? () => onRead(ReadIn.moves) : onTrain,
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
            _menu(status),
          ],
        ),
      ),
    );
  }
}

extension on _LineRow {
  /// What can be done to the line: train it alone, read it, put it on the
  /// schedule or take it off, leave it out of training or bring it back. A
  /// game can only be read.
  Widget _menu(LineStatus status) {
    const doing = 'save training progress';
    final trained = status == LineStatus.due || status == LineStatus.learned;
    final reads = [
      rowAction('Read', () => onRead(ReadIn.moves), busy: false),
      if (offerBuilder)
        rowAction('Open in Builder', () => onRead(ReadIn.builder), busy: false),
    ];
    if (status == LineStatus.game) return RowActions(children: reads);
    return RowActions(
      children: [
        rowAction('Train this line', onTrain, busy: false),
        ...reads,
        if (trained)
          rowAction(
            'Forget this line',
            () => onChange(progress.mark([line], known: false), doing),
            busy: progress.stale,
          )
        else if (status == LineStatus.untrained)
          rowAction(
            'I know this line',
            () => onChange(progress.mark([line], known: true), doing),
            busy: progress.stale,
          ),
        rowAction(
          status == LineStatus.excluded
              ? 'Include in training'
              : 'Exclude from training',
          () => onChange(
            progress.setExcluded(line, excluded: status != LineStatus.excluded),
            doing,
          ),
          busy: progress.stale,
        ),
      ],
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow({
    required this.mistake,
    required this.line,
    required this.onShow,
  });

  final Attempt mistake;
  final String? line;

  /// Puts the position the mistake was made in on the board; null for a
  /// line the scope no longer has.
  final VoidCallback? onShow;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final number = _number(mistake);
    return InkWell(
      onTap: onShow,
      child: SizedBox(
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
