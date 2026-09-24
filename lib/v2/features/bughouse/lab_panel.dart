import 'package:flutter/material.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/app_action.dart';
import '../../ui/theme.dart';
import 'archive_moves.dart';
import 'bughouse_lab.dart';
import 'move_tables.dart';
import 'table_search.dart';

/// The right-hand side of the lab: the clock, the engine (its switch and,
/// while on, each seat's column of moves), a line for what was refused, and
/// the database: each board's moves with their scores from the book, the
/// FICS archive's continuations under each board's table.
class LabPanel extends StatelessWidget {
  const LabPanel({
    super.key,
    required this.lab,
    required this.search,
    required this.archive,
  });

  final BughouseLab lab;
  final TableSearch search;
  final ArchiveMoves archive;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([lab, search, archive]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TimeChips(lab: lab),
          _EngineBar(search: search),
          if (search.scores case ScoresFromBook(:final provenance))
            _SavedAnalysis(provenance: provenance, clock: lab.clock),
          if (search.lines case final LinesOn on)
            EngineLinesBlock(lab: lab, on: on),
          _StatusLine(lab: lab, search: search),
          Expanded(
            child: MoveTables(
              lab: lab,
              scores: search.scores,
              archive: archive,
            ),
          ),
        ],
      ),
    );
  }
}

/// Identity and budgets for the saved numbers, separate from the live lines.
class _SavedAnalysis extends StatelessWidget {
  const _SavedAnalysis({required this.provenance, required this.clock});
  final Map<String, Object?> provenance;
  final ClockCase clock;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      icon: const Icon(Icons.info_outline),
      label: Text(
        'Saved scores · ${provenance['nodes'] ?? '?'} / ${provenance['child_nodes'] ?? '?'} nodes',
      ),
      onPressed: () => showDialog<void>(context: context, builder: _dialog),
    ),
  );

  Widget _dialog(BuildContext context) => AlertDialog(
    title: const Text('Saved analysis'),
    content: SizedBox(
      width: labPanelMaxWidth,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in [
              (
                'Engine',
                provenance['engine_name'] ?? 'Unknown (legacy analysis)',
              ),
              ('Position search', '${provenance['nodes'] ?? '?'} nodes'),
              (
                'Reply search',
                '${provenance['child_nodes'] ?? '?'} nodes per move',
              ),
              ('Clock', clock.label),
              ('Completed', provenance['completed_at'] ?? 'Unknown'),
              ('Engine SHA-256', provenance['engine_sha256'] ?? 'Not recorded'),
              (
                'Network SHA-256',
                provenance['network_sha256'] ?? 'Not recorded',
              ),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SelectableText('$value'),
                  ],
                ),
              ),
            if (provenance['budget_note'] case final String note) Text(note),
            const Text(
              'Scores are calibrated to 0 = level, on Hivemind’s scale. Previous scores and search details are retained in the local database.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

/// The engine's switch and what it is doing, as the engine bar reads in
/// the other modes.
class _EngineBar extends StatelessWidget {
  const _EngineBar({required this.search});

  final TableSearch search;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String status, Color? colour) = switch (search.lines) {
      LinesStopped(:final trouble) => (_trouble(trouble), scheme.error),
      _ => ('Hivemind', null),
    };
    return Row(
      children: [
        SizedBox(
          height: engineBarHeight,
          child: FittedBox(
            child: Tooltip(
              message: withKey('Toggle engine', 'E'),
              child: Switch(
                value: search.engineOn,
                onChanged: (_) => search.toggleEngine(),
              ),
            ),
          ),
        ),
        const SizedBox(width: Space.xs),
        Expanded(
          child: Text(
            status,
            style: TextStyle(color: colour),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The clock case the scores and the engine answer for, as chips.
class _TimeChips extends StatelessWidget {
  const _TimeChips({required this.lab});

  final BughouseLab lab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: labLabelWidth,
            child: Text(
              'Time',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          Flexible(
            child: SegmentedButton<ClockCase>(
              segments: [
                for (final clock in ClockCase.values)
                  ButtonSegment(
                    value: clock,
                    label: Text(clock.label),
                    tooltip: clock.hint,
                  ),
              ],
              selected: {lab.clock},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (picked) => lab.setClock(picked.single),
            ),
          ),
        ],
      ),
    );
  }
}

String _trouble(EngineTrouble trouble) => switch (trouble) {
  EngineNotStarted(:final reason) => reason,
  SearchFailed(:final reason) => 'Analysis failed: $reason',
};

/// One line that never changes height: what was refused, or why the book
/// could not be read; empty otherwise.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.lab, required this.search});

  final BughouseLab lab;
  final TableSearch search;

  String get _said {
    if (lab.problem case final problem?) return _refused(problem);
    if (search.bookProblem case final problem?) {
      return 'The database could not be read: $problem';
    }
    return '';
  }

  static String _refused(TableRefusal refusal) => switch (refusal) {
    DropRefused() => 'That drop is not legal.',
    NotOnMove(:final side, :final board) =>
      'It is not ${side.name}’s turn on ${board.label.toLowerCase()}.',
    MoveRefused(:final uci) => '$uci is not legal here.',
    LineMisfits() => 'That line no longer fits the position.',
    StepRefused(:final move) =>
      'Can’t step there: ${move.san} on ${move.board.label.toLowerCase()} '
          'would have no piece to drop.',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_said.isEmpty) return const SizedBox(height: Space.s);
    return SizedBox(
      height: labStatusHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _said,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.error),
        ),
      ),
    );
  }
}

/// While the engine is on: a column per seat, A and B then C and D, each
/// team's three best joint actions across its two columns with the score
/// beside them, the team's score in its header. A seat not on move has
/// nothing in its column. The rows are there from the start and fill as a
/// pass ends, so nothing below moves. Pointing at a row draws it on both
/// boards; clicking plays it.
class EngineLinesBlock extends StatelessWidget {
  const EngineLinesBlock({super.key, required this.lab, required this.on});

  final BughouseLab lab;
  final LinesOn on;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _TeamLines(lab: lab, on: on, team: Team.ab),
        ),
        // The board tables' gutter, so the halves line up with them.
        const SizedBox(width: Space.s + 1),
        Expanded(
          child: _TeamLines(lab: lab, on: on, team: Team.cd),
        ),
      ],
    );
  }
}

class _TeamLines extends StatelessWidget {
  const _TeamLines({required this.lab, required this.on, required this.team});

  final BughouseLab lab;
  final LinesOn on;
  final Team team;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final found = on.lines[team];
    final hasMove = on.position.hasMove(team);
    final score = found?.advantage.forTeam(team);
    final rows = found?.rows ?? const [];
    final head = TextStyle(
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: labTableRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            border: Border(bottom: BorderSide(color: scheme.outline)),
          ),
          child: Row(
            children: [
              for (final board in BoardNumber.values)
                Expanded(
                  child: Text(
                    Seat.of(board, team.sideOn(board)).letter,
                    style: head,
                  ),
                ),
              Tooltip(
                message: '${on.zero.note} Hivemind’s scale, not pawns.',
                waitDuration: previewDelay,
                child: SizedBox(
                  width: labScoreWidth,
                  child: Text(
                    !hasMove ? '' : score?.text ?? '',
                    textAlign: TextAlign.right,
                    style: monoText.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < (rows.isEmpty ? 1 : rows.length); i++)
          ColoredBox(
            color: i.isOdd
                ? scheme.onSurface.withValues(alpha: 0.045)
                : scheme.surface,
            child: SizedBox(
              height: labTableRowHeight,
              child: i < rows.length
                  ? _JointRow(
                      lab: lab,
                      position: on.position,
                      team: team,
                      move: rows[i].move,
                      score: rows[i].score.forTeam(team),
                    )
                  : Text(
                      hasMove ? 'Thinking…' : 'Waiting for turn',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
            ),
          ),
      ],
    );
  }
}

class _JointRow extends StatelessWidget {
  const _JointRow({
    required this.lab,
    required this.position,
    required this.team,
    required this.move,
    required this.score,
  });

  final BughouseLab lab;
  final TablePosition position;
  final Team team;
  final JointMove move;
  final TableScore score;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => lab.preview.value = {
        for (final board in BoardNumber.values) board: ?move.on(board),
      },
      onExit: (_) => lab.preview.value = null,
      child: InkWell(
        onTap: () => lab.playJoint(move),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Row(
            children: [
              for (final board in BoardNumber.values)
                Expanded(
                  child: Text(
                    _half(board),
                    style: monoText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              SizedBox(
                width: labScoreWidth,
                child: Text(
                  score.text,
                  style: monoText,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// This team's move on [board], `sits`, or nothing when it is not on
  /// move there.
  String _half(BoardNumber board) {
    if (position.mover(board).team != team) return '';
    final uci = move.on(board);
    if (uci == null) return 'sits';
    return position.play(board, uci)?.move.san ?? uci;
  }
}
