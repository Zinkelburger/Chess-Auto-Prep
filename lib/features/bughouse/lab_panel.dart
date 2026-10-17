import 'package:dartchess/dartchess.dart' show Setup;
import 'package:flutter/material.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/fen.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/app_keys.dart';
import '../../ui/engine_switch.dart';
import '../../ui/theme.dart';
import '../../workspace/board_editor.dart';
import 'bughouse_lab.dart';
import 'lab_engine.dart';
import 'lab_lines.dart';
import 'table_boards.dart';

/// The column beside the boards: how many boards, who may sit,
/// the engine switch with its score, and with one board its best moves and
/// move list; with two, each board's best moves are under that board. Every
/// row keeps its height whether the engine is on or off.
class LabPanel extends StatelessWidget {
  const LabPanel({super.key, required this.lab, required this.engine});

  final BughouseLab lab;
  final LabEngine engine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([lab, engine]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BoardsSwitch(lab: lab),
          _TimeChips(lab: lab, lines: engine.lines),
          const SizedBox(height: Space.s),
          _EngineBar(engine: engine, single: lab.single),
          if (lab.single)
            BoardLineRows(
              lab: lab,
              lines: engine.lines,
              board: BoardNumber.one,
            ),
          _ProblemLine(lab: lab),
          if (lab.single)
            Expanded(
              child: BoardMoves(lab: lab, board: BoardNumber.one, fill: true),
            ),
        ],
      ),
    );
  }
}

class _BoardsSwitch extends StatelessWidget {
  const _BoardsSwitch({required this.lab});

  final BughouseLab lab;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SegmentedButton<LabBoards>(
        segments: const [
          ButtonSegment(
            value: LabBoards.one,
            label: Text('1 board'),
            tooltip: 'Analyse board 1 alone; its partner board stays as it is',
          ),
          ButtonSegment(
            value: LabBoards.two,
            label: Text('2 boards'),
            tooltip: 'Analyse both boards of the game',
          ),
        ],
        selected: {lab.boards},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        onSelectionChanged: (picked) => lab.showBoards(picked.single),
      ),
      const Spacer(),
      Tooltip(
        message: lab.single
            ? 'Place, move or remove pieces on the board'
            : 'Place, move or remove pieces on ${lab.focus.label.toLowerCase()}',
        child: OutlinedButton(
          onPressed: () => _edit(context),
          child: const Text('Edit board'),
        ),
      ),
    ],
  );

  /// The board in the board editor, its hands left as they are.
  Future<void> _edit(BuildContext context) async {
    final board = lab.single ? BoardNumber.one : lab.focus;
    final fen = await showBoardEditor(
      context,
      initial: Fen(_withoutHands(lab.position.board(board).fen)),
      title: lab.single
          ? 'Edit the board'
          : 'Edit ${board.label.toLowerCase()}',
      orientation: lab.bottom(board),
    );
    if (fen == null || !context.mounted) return;
    lab.editBoard(board, Setup.parseFen(fen.value));
  }
}

/// A crazyhouse FEN as plain chess: no hands, no promoted marks.
String _withoutHands(String fen) =>
    fen.replaceFirst(RegExp(r'\[[^\]]*\]'), '').replaceAll('~', '');

/// The clock case the engine answers for: who may sit rather than move.
/// While the engine is on, each case shows A + B's score under it, the
/// chosen one live and the others once a short search has scored them, so
/// sitting and not sitting can be compared at a glance.
class _TimeChips extends StatelessWidget {
  const _TimeChips({required this.lab, required this.lines});

  final BughouseLab lab;
  final LabLines lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = this.lines;
    final on = lines is LinesOn && lines.boards == lab.boards ? lines : null;
    String scoreOf(ClockCase clock) {
      if (on == null) return '';
      final score = clock == lab.clock
          ? (on.nodes == null ? null : on.score)
          : on.byClock[clock];
      return score?.text ?? '–';
    }

    return Padding(
      padding: const EdgeInsets.only(top: Space.s),
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
                    label: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_label(clock)),
                        Text(
                          scoreOf(clock),
                          style: monoText.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    tooltip: _hint(clock),
                  ),
              ],
              selected: {lab.clock},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
                ),
              ),
              onSelectionChanged: (picked) => lab.setClock(picked.single),
            ),
          ),
        ],
      ),
    );
  }

  /// With one board the seats are not shown: the cases name the colours.
  String _label(ClockCase clock) => !lab.single
      ? clock.label
      : switch (clock) {
          ClockCase.abMaySit => 'White may sit',
          ClockCase.even => 'Even',
          ClockCase.cdMaySit => 'Black may sit',
        };

  /// What the case means, then what its number is.
  String _hint(ClockCase clock) {
    if (!lab.single) {
      return '${clock.hint}. The number under it is A + B’s score then.';
    }
    final means = switch (clock) {
      ClockCase.abMaySit =>
        'White is up on the clock, so can wait rather than move',
      ClockCase.even => 'Neither side is up on the clock: both have to move',
      ClockCase.cdMaySit =>
        'Black is up on the clock, so can wait rather than move',
    };
    return '$means. The number under it is White’s score then.';
  }
}

/// The switch, the score, the engine's name with the size of the search
/// shown, and a thin bar while it runs: how far towards the size it rests
/// at, or moving without a measure while an engine searches in passes.
class _EngineBar extends StatelessWidget {
  const _EngineBar({required this.engine, required this.single});

  final LabEngine engine;
  final bool single;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = engine.lines;
    final (String status, Color colour) = switch (lines) {
      LinesStopped(:final reason) => (reason, scheme.error),
      LinesOn(nodes: final nodes?) => (
        'Hivemind · ${_thousands(nodes)} nodes',
        scheme.onSurfaceVariant,
      ),
      _ => ('Hivemind', scheme.onSurfaceVariant),
    };
    final score = lines is LinesOn && lines.nodes != null
        ? lines.score.text
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: engineBarHeight,
          child: Row(
            children: [
              Tooltip(
                message: AppKey.bughouseEngine.tip('Toggle engine'),
                child: EngineSwitch(
                  value: engine.on,
                  onChanged: (_) => engine.toggle(),
                ),
              ),
              const SizedBox(width: Space.s),
              Tooltip(
                message: scoreHint(single: single),
                child: SizedBox(
                  width: labPearlWidth,
                  child: Text(score, style: labPearlText),
                ),
              ),
              Expanded(
                child: Text(
                  status,
                  style: TextStyle(color: colour),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: labThinkingHeight,
          child: lines is LinesOn && lines.thinking
              ? LinearProgressIndicator(
                  minHeight: labThinkingHeight,
                  value: lines.progress,
                )
              : null,
        ),
      ],
    );
  }
}

String _thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// Why the last move, step or paste was refused, in a line that keeps its
/// height when there is nothing to say.
class _ProblemLine extends StatelessWidget {
  const _ProblemLine({required this.lab});

  final BughouseLab lab;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: labStatusHeight,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        switch (lab.problem) {
          final problem? => _refused(problem),
          null => '',
        },
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ),
  );

  static String _refused(TableRefusal refusal) => switch (refusal) {
    DropRefused() => 'That drop is not legal.',
    NotOnMove(:final side, :final board) =>
      'It is not ${side.name}’s turn on ${board.label.toLowerCase()}.',
    MoveRefused(:final uci) => '$uci is not legal here.',
    LineMisfits() => 'That line no longer fits the position.',
    PositionRefused(:final reason) => reason,
    MovesRefused(token: null, file: null) => 'No bughouse moves to paste.',
    MovesRefused(token: null, :final file?) => 'No bughouse moves in $file.',
    MovesRefused(:final token?, file: null) =>
      'Not pasted: $token does not play.',
    MovesRefused(:final token?, :final file?) =>
      'Not opened: $token in $file does not play.',
    FileUnread(:final file) => '$file could not be read.',
    StepRefused(:final move) =>
      'Can’t step there: ${move.san} on ${move.board.label.toLowerCase()} '
          'would have no piece to drop.',
    DeleteRefused(:final move) =>
      'Can’t delete: ${move.san} on ${move.board.label.toLowerCase()} '
          'would have no piece to drop.',
  };
}
