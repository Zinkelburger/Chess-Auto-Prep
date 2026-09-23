import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/theme.dart';
import 'archive_moves.dart';
import 'bughouse_lab.dart';
import 'move_tables.dart';
import 'table_search.dart';

/// The right-hand side of the lab: the question as chips — our team, a
/// board that must be moved on, the clock, how long Analyze searches — the
/// buttons, one status line that never changes height, what Analyze found,
/// and each board's moves with their scores, the FICS archive under them
/// while it is open.
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
          _Choice<Team>(
            label: 'Our team',
            values: Team.values,
            chosen: lab.team,
            name: (team) => team.label,
            onChosen: lab.setTeam,
          ),
          _Choice<MustMove>(
            label: 'Must move on',
            values: MustMove.values,
            chosen: lab.mustMove,
            name: (rule) => rule.label,
            onChosen: lab.setMustMove,
          ),
          _Choice<ClockCase>(
            label: 'Time',
            values: ClockCase.values,
            chosen: lab.clock,
            name: (clock) => clock.label,
            hint: (clock) => clock.hint,
            onChosen: lab.setClock,
          ),
          _Choice<Duration>(
            label: 'Search',
            values: searchBudgets,
            chosen: lab.budget,
            name: (budget) => '${budget.inSeconds} s',
            onChosen: lab.setBudget,
          ),
          const SizedBox(height: Space.xs),
          _Buttons(lab: lab, search: search, archive: archive),
          _StatusLine(lab: lab, search: search),
          if (search.analysis case final AnalysisDone done)
            AnalysisRows(lab: lab, done: done),
          Expanded(
            child: MoveTables(lab: lab, scores: search.scores),
          ),
          if (archive.shown)
            Expanded(
              child: ArchiveBlock(lab: lab, archive: archive),
            ),
        ],
      ),
    );
  }
}

/// One question as a row of chips under its label.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.values,
    required this.chosen,
    required this.name,
    required this.onChosen,
    this.hint,
  });

  final String label;
  final List<T> values;
  final T chosen;
  final String Function(T value) name;
  final String Function(T value)? hint;
  final ValueChanged<T> onChosen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s),
      child: Row(
        children: [
          SizedBox(
            width: labLabelWidth,
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          Flexible(
            child: SegmentedButton<T>(
              segments: [
                for (final value in values)
                  ButtonSegment(
                    value: value,
                    label: Text(name(value)),
                    tooltip: hint?.call(value),
                  ),
              ],
              selected: {chosen},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (picked) => onChosen(picked.single),
            ),
          ),
        ],
      ),
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons({
    required this.lab,
    required this.search,
    required this.archive,
  });

  final BughouseLab lab;
  final TableSearch search;
  final ArchiveMoves archive;

  @override
  Widget build(BuildContext context) {
    final running = search.analysis is AnalysisRunning;
    // The search's buttons at the left, the table's at the right; a narrow
    // panel puts the second pair under the first rather than overflow.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      runSpacing: Space.s,
      children: [
        Wrap(
          spacing: Space.s,
          children: [
            if (running)
              OutlinedButton(
                onPressed: search.stopAnalysis,
                child: const Text('Stop'),
              )
            else
              FilledButton(
                onPressed: () => unawaited(search.analyze()),
                child: const Text('Analyze'),
              ),
            if (archive.available)
              OutlinedButton(
                onPressed: archive.toggle,
                child: Text(
                  archive.shown ? 'Hide FICS archive' : 'FICS archive',
                ),
              ),
          ],
        ),
        Wrap(
          spacing: Space.s,
          children: [
            OutlinedButton(
              onPressed: lab.flip,
              child: const Text('Flip boards'),
            ),
            OutlinedButton(
              onPressed: lab.newGame,
              child: const Text('New game'),
            ),
          ],
        ),
      ],
    );
  }
}

/// One line, always there, saying what the tables and the engine are
/// doing, or what was refused; in the error colour only for a failure.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.lab, required this.search});

  final BughouseLab lab;
  final TableSearch search;

  (String, bool) get _said {
    if (lab.problem case final problem?) return (problem, true);
    switch (search.analysis) {
      case AnalysisRunning(:final team):
        return team == lab.team
            ? ('Hivemind is searching for ${team.label}…', false)
            : ('Comparing ${team.label}…', false);
      case AnalysisFailed(:final reason):
        return (reason, true);
      case AnalysisNoMove(:final team):
        return ('${team.label} has no move here.', false);
      case AnalysisIdle() || AnalysisDone():
        break;
    }
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
      ScoresFailed(:final reason) => (reason, true),
    };
  }

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

/// What Analyze found: our team's score and up to three joint actions, each
/// board's half named by the seat that plays it. Pointing at a row draws it
/// on both boards; clicking plays it.
class AnalysisRows extends StatelessWidget {
  const AnalysisRows({super.key, required this.lab, required this.done});

  final BughouseLab lab;
  final AnalysisDone done;

  String get _headline {
    final score = done.advantage.forTeam(done.team);
    if (score.mate case final mate?) {
      return mate > 0
          ? 'Mate for ${done.team.label}'
          : 'Mate against ${done.team.label}';
    }
    return '${done.team.label}: ${score.text}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: '${done.zero.note} Hivemind’s scale, not pawns.',
            child: Text(
              _headline,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          for (final (i, row) in done.rows.indexed)
            _JointRow(
              lab: lab,
              done: done,
              label: i == 0 ? 'Best' : '${i + 1}',
              move: row.move,
              score: row.score.forTeam(done.team),
            ),
        ],
      ),
    );
  }
}

class _JointRow extends StatelessWidget {
  const _JointRow({
    required this.lab,
    required this.done,
    required this.label,
    required this.move,
    required this.score,
  });

  final BughouseLab lab;
  final AnalysisDone done;
  final String label;
  final JointMove move;
  final TableScore score;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final halves = teamHalves(done.position, move, done.team);
    return MouseRegion(
      onEnter: (_) => lab.preview.value = {
        for (final board in BoardNumber.values) board: ?move.on(board),
      },
      onExit: (_) => lab.preview.value = null,
      child: InkWell(
        onTap: () => lab.playJoint(move),
        child: SizedBox(
          height: labTableRowHeight,
          child: Row(
            children: [
              SizedBox(
                width: labLabelWidth,
                child: Text(
                  label,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              for (final board in BoardNumber.values)
                Expanded(child: Text(halves[board] ?? '', style: monoText)),
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
}
