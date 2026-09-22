import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/tactics/puzzle.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'puzzle_filters.dart';
import 'puzzle_trainer.dart';
import 'tactics_set.dart';

/// The Tactics column: the one button that starts a sitting, the filters
/// beside the count they change, and the puzzles they let through, which
/// are exactly what the button plays, in its order. A puzzle clicked in the
/// list comes up on the board at once.
///
/// The panel keeps what the user typed into the search box and whether the
/// filters are open; everything else is the set's and the trainer's.
class TacticsPanel extends StatefulWidget {
  const TacticsPanel({
    super.key,
    required this.set,
    required this.trainer,
    required this.onPlay,
    this.trailing,
  });

  final TacticsSet set;
  final PuzzleTrainer trainer;

  /// Starts a sitting from [first], or from the top of the queue: the host
  /// also brings the Puzzle tab up.
  final void Function({Puzzle? first}) onPlay;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<TacticsPanel> createState() => _TacticsPanelState();
}

class _TacticsPanelState extends State<TacticsPanel> {
  final _search = TextEditingController();
  String _query = '';
  bool _filtersOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.set.load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _searched(String query) {
    if (mounted) setState(() => _query = query);
  }

  void _toggleFilters() {
    if (mounted) setState(() => _filtersOpen = !_filtersOpen);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.set, widget.trainer]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(trailing: widget.trailing),
          Expanded(
            child: switch (widget.set.state) {
              SetLoading() => const SizedBox.shrink(),
              SetMissing() => const _Message(
                'No puzzles yet. The old app\'s game review mines them into '
                'tactics_sets/Default.pgn.',
              ),
              SetUnreadable(:final detail) => _Message(
                'The puzzle set could not be read: $detail',
              ),
              SetReady() => _ready(context),
            },
          ),
        ],
      ),
    );
  }

  /// The Play button stays put; everything under it — the count, the
  /// filters when open, the search box and the rows — scrolls as one, so
  /// opening the filters in a short window never squeezes the list away.
  Widget _ready(BuildContext context) {
    final queue = widget.set.queue;
    final shown = _query.isEmpty
        ? queue
        : [
            for (final puzzle in queue)
              if (puzzle.matches(_query)) puzzle,
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
          child: FilledButton(
            onPressed: queue.isEmpty ? null : () => widget.onPlay(),
            child: Text('Play tactics (${queue.length})'),
          ),
        ),
        Expanded(child: _list(queue, shown)),
      ],
    );
  }

  Widget _list(List<Puzzle> queue, List<Puzzle> shown) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: _CountLine(
          queue: queue,
          total: widget.set.puzzles.length,
          filtersOpen: _filtersOpen,
          onFilters: _toggleFilters,
        ),
      ),
      if (_filtersOpen)
        SliverToBoxAdapter(
          child: PuzzleFilters(
            filter: widget.set.filter,
            onChanged: widget.set.setFilter,
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.m,
            Space.s,
            Space.s,
            Space.s,
          ),
          child: SearchField(
            controller: _search,
            hint: 'Search by player, date or move',
            onChanged: _searched,
          ),
        ),
      ),
      _rows(shown, queue.isEmpty),
    ],
  );

  Widget _rows(List<Puzzle> shown, bool noneQueued) {
    if (shown.isEmpty) {
      return SliverToBoxAdapter(
        child: _Message(
          noneQueued
              ? 'Your filters rule out every puzzle you have. Open Filters '
                    'to loosen them.'
              : 'Nothing matches "$_query".',
        ),
      );
    }
    final current = widget.trainer.up?.puzzle.index;
    final outcomes = widget.trainer.run?.outcomes ?? const {};
    return SliverFixedExtentList(
      itemExtent: puzzleRowHeight,
      delegate: SliverChildBuilderDelegate(childCount: shown.length, (
        context,
        at,
      ) {
        final puzzle = shown[at];
        return _PuzzleRow(
          puzzle: puzzle,
          open: puzzle.index == current,
          outcome: outcomes[puzzle.fen]?.name,
          onOpen: () => widget.onPlay(first: puzzle),
        );
      }),
    );
  }
}

/// The panel's name and the host's toggle in the corner.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.trailing});

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Tactics',
              style: Theme.of(context).textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// How many puzzles the filters let through and what they are, with the
/// way to the filters beside it.
class _CountLine extends StatelessWidget {
  const _CountLine({
    required this.queue,
    required this.total,
    required this.filtersOpen,
    required this.onFilters,
  });

  final List<Puzzle> queue;
  final int total;
  final bool filtersOpen;
  final VoidCallback onFilters;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.xs, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${queue.length} of $total',
                  style: text.labelSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: onFilters,
                icon: Icon(
                  filtersOpen ? Icons.expand_less : Icons.expand_more,
                  size: IconSize.action,
                ),
                iconAlignment: IconAlignment.end,
                label: const Text('Filters'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: Space.s),
            child: Text(_kinds(queue), style: text.labelSmall),
          ),
        ],
      ),
    );
  }

  /// `14 blunders, 12 mistakes`: each kind the queue holds, worst first.
  static String _kinds(List<Puzzle> queue) {
    final parts = [
      for (final kind in MistakeKind.values)
        if (queue.where((p) => p.kind == kind).length case final n when n > 0)
          '$n ${n == 1 ? kind.word : kind.plural}',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }
}

/// One puzzle: the move played and how it has gone on the first line, who
/// it was against and when on the second.
class _PuzzleRow extends StatelessWidget {
  const _PuzzleRow({
    required this.puzzle,
    required this.open,
    required this.outcome,
    required this.onOpen,
  });

  final Puzzle puzzle;

  /// This is the puzzle on the board.
  final bool open;

  /// `solved` or `failed` in the sitting under way, or null.
  final String? outcome;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = puzzle.stats;
    final record = stats.isNew ? 'new' : '${stats.successes}/${stats.reviews}';
    return Material(
      color: open ? theme.colorScheme.surfaceContainerHighest : null,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      puzzle.label,
                      style: monoText,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    outcome ?? record,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: outcome == 'failed'
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
              ),
              Text(
                [
                  if (puzzle.opponent.isNotEmpty) 'vs ${puzzle.opponent}',
                  if (puzzle.date.isNotEmpty) puzzle.date,
                ].join(' · '),
                style: theme.textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
