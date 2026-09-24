import 'package:flutter/material.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/app_action.dart';
import '../../ui/theme.dart';
import 'archive_moves.dart';
import 'bughouse_lab.dart';
import 'move_tables.dart';
import 'table_search.dart';

/// The right-hand side of the lab: the engine switch, the clock, one status
/// line that never changes height, each team's best lines while the engine
/// is on, and each board's moves with their scores, the FICS archive's
/// continuations under each board's table.
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
          _EngineBar(search: search),
          const SizedBox(height: Space.xs),
          _TimeChips(lab: lab),
          _StatusLine(lab: lab, search: search),
          if (search.lines case final LinesOn on)
            EngineLinesBlock(lab: lab, on: on),
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

/// The engine's switch and what it is doing, as the engine bar reads in
/// the other modes.
class _EngineBar extends StatelessWidget {
  const _EngineBar({required this.search});

  final TableSearch search;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String status, Color? colour) = switch (search.lines) {
      LinesOff() => ('Engine', null),
      LinesStopped(:final trouble) => (_trouble(trouble), scheme.error),
      LinesOn(:final thinking?, :final lines) => (
        lines.isEmpty
            ? 'Hivemind · starting…'
            : 'Hivemind · thinking ${thinking.inSeconds} s a team',
        null,
      ),
      LinesOn() => ('Hivemind', null),
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

/// One line, always there, saying where the tables' scores come from, or
/// what was refused; in the error colour only for a failure.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.lab, required this.search});

  final BughouseLab lab;
  final TableSearch search;

  (String, bool) get _said {
    if (lab.problem case final problem?) return (_refused(problem), true);
    if (search.bookProblem case final problem?) {
      return ('The Hivemind book could not be read: $problem', true);
    }
    return switch (search.scores) {
      ScoresWaiting() => ('Looking the position up…', false),
      ScoresFromBook() => ('From the Hivemind book.', false),
      ScoresSearched(:final done, :final total, :final finished) =>
        finished
            ? ('Not in the book · Hivemind scored the likeliest moves.', false)
            : ('Not in the book · searching $done of $total…', false),
      ScoresFailed(:final trouble) => (_trouble(trouble), true),
    };
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
    final (text, failed) = _said;
    return SizedBox(
      height: labStatusHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: failed ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// While the engine is on: each team's score and its three best joint
/// actions side by side, each board's half named by the seat that plays
/// it. The rows are there from the start and fill as a pass ends, so
/// nothing below moves. Pointing at a row draws it on both boards;
/// clicking plays it.
class EngineLinesBlock extends StatelessWidget {
  const EngineLinesBlock({super.key, required this.lab, required this.on});

  final BughouseLab lab;
  final LinesOn on;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.s),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final team in Team.values) ...[
            if (team == Team.cd)
              const Padding(padding: EdgeInsets.symmetric(horizontal: Space.m)),
            Expanded(
              child: _TeamLines(lab: lab, on: on, team: team),
            ),
          ],
        ],
      ),
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
    final headline = !hasMove ? 'no move' : score?.text ?? '…';
    final rows = found?.rows ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: labTableRowHeight,
          child: Tooltip(
            message: '${on.zero.note} Hivemind’s scale, not pawns.',
            waitDuration: previewDelay,
            child: Row(
              children: [
                Text(
                  team.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  headline,
                  style: monoText.copyWith(
                    fontWeight: FontWeight.w600,
                    color: score == null ? scheme.onSurfaceVariant : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        for (var i = 0; i < 3; i++)
          SizedBox(
            height: labTableRowHeight,
            child: i < rows.length
                ? _JointRow(
                    lab: lab,
                    position: on.position,
                    team: team,
                    move: rows[i].move,
                    score: rows[i].score.forTeam(team),
                  )
                : null,
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
    final halves = teamHalves(position, move, team);
    return MouseRegion(
      onEnter: (_) => lab.preview.value = {
        for (final board in BoardNumber.values) board: ?move.on(board),
      },
      onExit: (_) => lab.preview.value = null,
      child: InkWell(
        onTap: () => lab.playJoint(move),
        child: Row(
          children: [
            Expanded(
              child: Text(
                [
                  for (final board in BoardNumber.values) ?halves[board],
                ].join(' · '),
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
    );
  }
}
