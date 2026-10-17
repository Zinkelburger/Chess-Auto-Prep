import 'dart:async';

import 'package:dartchess/dartchess.dart' show Crazyhouse, Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/bughouse/pv_steps.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/action_context_menu.dart';
import '../../ui/app_action.dart';
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import '../../workspace/line_preview.dart';
import 'bughouse_lab.dart';
import 'lab_engine.dart';
import 'pocket.dart';

/// The board a hovered engine move floats: the board it was played on,
/// after it, with its hands.
typedef _Hovered = ({
  Crazyhouse board,
  String uci,
  Side orientation,
  Offset anchor,
});

/// Moves of an engine line shown in a row.
const _oneBoardMoves = 8;
const _twoBoardActions = 4;

/// The engine's lines under its bar, as the workspace's engine lines work:
/// each move is its own token; resting on one floats the board it is on
/// after it, hands and all, and clicking one plays the line up to it. The
/// right button copies the line as PGN. One board: three rows of board 1's
/// moves. Two boards: each team's header over three rows of seat-lettered
/// joint actions. Every row is 28 px whether it holds a line or not, and
/// nothing hovered changes its size.
class LabLineRows extends StatefulWidget {
  const LabLineRows({super.key, required this.lab, required this.lines});

  final BughouseLab lab;
  final LabLines lines;

  @override
  State<LabLineRows> createState() => _LabLineRowsState();
}

class _LabLineRowsState extends State<LabLineRows> {
  final _hovered = ValueNotifier<_Hovered?>(null);
  Timer? _settle;

  BughouseLab get lab => widget.lab;

  /// Rows for another table take the floated board with them; a deeper
  /// search of the same table keeps it.
  @override
  void didUpdateWidget(LabLineRows old) {
    super.didUpdateWidget(old);
    if (_tableOf(old.lines) != _tableOf(widget.lines)) _leave();
  }

  static String? _tableOf(LabLines lines) =>
      lines is LinesOn ? '${lines.position.dualFen} ${lines.boards}' : null;

  @override
  void dispose() {
    _settle?.cancel();
    _hovered.dispose();
    super.dispose();
  }

  /// The board appears once the pointer has rested on a move.
  void _hover(PvStep step, Offset anchor) {
    final uci = step.uci;
    if (uci == null) return;
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      _hovered.value = (
        board: step.after.board(step.board),
        uci: uci,
        orientation: lab.bottom(step.board),
        anchor: anchor,
      );
    });
  }

  void _leave() {
    _settle?.cancel();
    _hovered.value = null;
  }

  void _play(List<PvStep> steps, int index) {
    _leave();
    lab.playMoves(pvMovesTo(steps, index));
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    final on = lines is LinesOn && lines.boards == lab.boards ? lines : null;
    return FloatingPreview<_Hovered>(
      preview: _hovered,
      anchor: (hovered) => hovered.anchor,
      size: BughousePreviewBoard.size,
      builder: (context, hovered) => BughousePreviewBoard(
        position: hovered.board,
        orientation: hovered.orientation,
        lastMove: hovered.uci,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: lab.single
            ? _rows(on?.teams.values.firstOrNull)
            : [
                for (final team in Team.values) ...[
                  _TeamHeader(team: team),
                  ..._rows(on?.teams[team]),
                ],
              ],
      ),
    );
  }

  List<Widget> _rows(List<EngineRow>? rows) => [
    for (var i = 0; i < labLineCount; i++)
      if (rows != null && i < rows.length)
        _row(rows[i])
      else
        const SizedBox(height: labTableRowHeight),
  ];

  Widget _row(EngineRow row) {
    final single = lab.single;
    final steps = pvSteps(
      row.table,
      row.pv,
      board: single ? BoardNumber.one : null,
      limit: single ? _oneBoardMoves : _twoBoardActions,
    );
    return _LineRow(
      score: row.score.text,
      steps: steps,
      onEnter: () => lab.preview.value = {
        for (final board in BoardNumber.values)
          if (!single || board == BoardNumber.one) board: ?row.move.on(board),
      },
      onExit: () {
        _leave();
        lab.preview.value = null;
      },
      onTap: () {
        _leave();
        if (!single) return lab.playJoint(row.move);
        if (row.move.one case final uci?) lab.play(BoardNumber.one, uci);
      },
      onHover: _hover,
      onLeave: _leave,
      onPlay: (index) => _play(steps, index),
      menu: () => [
        AppAction('Copy line PGN', () {
          final all = pvSteps(
            row.table,
            row.pv,
            board: single ? BoardNumber.one : null,
            limit: row.pv.length * 2,
          );
          final text = lab.linePgnWith(pvMovesTo(all, all.length - 1));
          unawaited(Clipboard.setData(ClipboardData(text: text)));
        }),
      ],
    );
  }
}

class _TeamHeader extends StatelessWidget {
  const _TeamHeader({required this.team});

  final Team team;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: labTableRowHeight,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: Text(
        team.label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// One engine line: the score in a mono gutter, then its moves, clipped to
/// the row. Pointing at the row draws its first move on the board; a click
/// outside the moves plays that first move.
class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.score,
    required this.steps,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
    required this.onHover,
    required this.onLeave,
    required this.onPlay,
    required this.menu,
  });

  final String score;
  final List<PvStep> steps;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;
  final void Function(PvStep step, Offset anchor) onHover;
  final VoidCallback onLeave;
  final ValueChanged<int> onPlay;
  final List<AppAction> Function() menu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = <Widget>[];
    for (final (i, step) in steps.indexed) {
      if (i > 0 && step.joint != steps[i - 1].joint) {
        tokens.add(_Separator(colour: scheme.onSurfaceVariant));
      }
      tokens.add(
        _StepToken(
          step: step,
          onHover: (anchor) => onHover(step, anchor),
          onLeave: onLeave,
          onTap: () => onPlay(i),
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        onSecondaryTapUp: (details) => unawaited(
          showActionContextMenu(context, details.globalPosition, menu()),
        ),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: labTableRowHeight,
            child: Row(
              children: [
                SizedBox(
                  width: labScoreWidth,
                  child: Text(
                    score,
                    style: monoText.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: ClipRect(
                    child: Wrap(clipBehavior: Clip.hardEdge, children: tokens),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: labTableRowHeight,
    child: Center(
      widthFactor: 1,
      child: Text(' · ', style: monoText.copyWith(color: colour)),
    ),
  );
}

/// One move of a line: what goes before it muted, the move in the text
/// colour, a tint under the pointer. A `sit` is muted and does nothing.
class _StepToken extends StatelessWidget {
  const _StepToken({
    required this.step,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final PvStep step;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  /// The bottom centre of this token on the screen, where its board hangs.
  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      // As wide as its text, or the row's loose width would be taken.
      child: Center(
        widthFactor: 1,
        child: Text.rich(
          TextSpan(
            children: [
              if (step.label.isNotEmpty)
                TextSpan(
                  text: '${step.label} ',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              TextSpan(text: displaySan(context, step.san)),
            ],
          ),
          style: monoText.copyWith(
            color: step.uci == null
                ? scheme.onSurfaceVariant
                : scheme.onSurface,
          ),
        ),
      ),
    );
    if (step.uci == null) {
      return SizedBox(height: labTableRowHeight, child: text);
    }
    return SizedBox(
      height: labTableRowHeight,
      child: MouseRegion(
        onEnter: (_) => onHover(_anchor(context)),
        onExit: (_) => onLeave(),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(3),
          hoverColor: scheme.primary.withValues(alpha: 0.1),
          child: text,
        ),
      ),
    );
  }
}
