import 'dart:async';

import 'package:dartchess/dartchess.dart' show Crazyhouse, Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/bughouse/pv_steps.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/action_context_menu.dart';
import '../../ui/app_action.dart';
import '../../ui/theme.dart';
import '../../workspace/board/line_preview.dart';
import '../../workspace/board/preview_target.dart';
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
const _rowMoves = 8;

/// What a row's score means, on its tooltip.
String scoreHint({required bool single}) => single
    ? '+ is good for White on board 1 (A + B). Hivemind’s scale, not pawns.'
    : '+ is good for A + B: White on board 1, Black on board 2. '
          'Hivemind’s scale, not pawns.';

/// One board's best moves for the player on move there, as lila's engine
/// lines: a row per move, its score, then the moves of that board that
/// follow, each its own token. Resting on a move floats the board it is on
/// after it, hands and all, and clicking one plays the line up to it — with
/// both boards shown, the other board's moves before it too. Pointing at a
/// row draws its move on the board; clicking the row plays it there. The
/// right button copies the line as PGN. Every row is 28 px whether it holds
/// a move or not, and nothing hovered changes its size.
class BoardLineRows extends StatefulWidget {
  const BoardLineRows({
    super.key,
    required this.lab,
    required this.lines,
    required this.board,
  });

  final BughouseLab lab;
  final LabLines lines;
  final BoardNumber board;

  @override
  State<BoardLineRows> createState() => _BoardLineRowsState();
}

class _BoardLineRowsState extends State<BoardLineRows> {
  final _hovered = HoverPreview<_Hovered>();

  BughouseLab get lab => widget.lab;
  BoardNumber get board => widget.board;

  /// Rows for another table take the floated board with them; a deeper
  /// search of the same table keeps it.
  @override
  void didUpdateWidget(BoardLineRows old) {
    super.didUpdateWidget(old);
    if (_tableOf(old.lines) != _tableOf(widget.lines)) _leave();
  }

  static String? _tableOf(LabLines lines) =>
      lines is LinesOn ? '${lines.position.dualFen} ${lines.boards}' : null;

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  /// The board appears once the pointer has rested on a move.
  void _hover(PvStep step, Offset anchor) {
    final uci = step.uci;
    if (uci == null) return;
    _hovered.rest(
      () => (
        board: step.after.board(step.board),
        uci: uci,
        orientation: lab.bottom(step.board),
        anchor: anchor,
      ),
    );
  }

  void _leave() {
    _hovered.leave();
  }

  void _play(List<PvStep> steps, int index) {
    _leave();
    lab.playMoves(pvMovesTo(steps, index));
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    final rows = lines is LinesOn && lines.boards == lab.boards
        ? lines.rows[board]
        : null;
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
        children: [
          for (var i = 0; i < labLineCount; i++)
            if (rows != null && i < rows.length)
              _row(rows[i])
            else
              const SizedBox(height: labTableRowHeight),
        ],
      ),
    );
  }

  List<PvStep> _steps(EngineRow row, int limit) => pvSteps(
    row.table,
    row.pv,
    board: board,
    throughBoth: !lab.single,
    limit: limit,
  );

  Widget _row(EngineRow row) {
    final steps = _steps(row, _rowMoves);
    final move = row.move;
    return _LineRow(
      score: row.score.text,
      scoreHint: scoreHint(single: lab.single),
      sits: move == null,
      steps: steps,
      onEnter: () => lab.preview.value = move == null ? null : {board: move},
      onExit: () {
        _leave();
        lab.preview.value = null;
      },
      onTap: () {
        _leave();
        if (move != null) lab.play(board, move);
      },
      onHover: _hover,
      onLeave: _leave,
      onPlay: (index) => _play(steps, index),
      menu: () => [
        AppAction('Copy line PGN', () {
          final all = _steps(row, row.pv.length * 2);
          final text = lab.linePgnWith(pvMovesTo(all, all.length - 1));
          unawaited(Clipboard.setData(ClipboardData(text: text)));
        }, icon: Icons.content_copy),
      ],
    );
  }
}

/// One engine line: the score in a mono gutter, then its moves, clipped to
/// the row, the first in bold: the move the row is about. A row that sits
/// says so first, muted. Pointing at the row draws its move on the board; a
/// click outside the moves plays it.
class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.score,
    required this.scoreHint,
    required this.sits,
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
  final String scoreHint;

  /// Whether the row's choice is to sit on its board rather than move.
  final bool sits;
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
    final tokens = <Widget>[
      if (sits)
        Tooltip(
          message: 'Sit: wait here rather than move',
          waitDuration: previewDelay,
          child: SizedBox(
            height: labTableRowHeight,
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text(
                  'sit',
                  style: monoText.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      for (final (i, step) in steps.indexed)
        // A `sit` is muted and does nothing.
        LineMoveToken(
          label: step.label,
          san: step.san,
          height: labTableRowHeight,
          strong: i == 0 && !sits,
          onHover: (anchor) => onHover(step, anchor),
          onLeave: onLeave,
          onTap: step.uci == null ? null : () => onPlay(i),
        ),
    ];
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
                Tooltip(
                  message: scoreHint,
                  waitDuration: previewDelay,
                  child: SizedBox(
                    width: labScoreWidth,
                    child: Text(
                      score,
                      style: monoText.copyWith(fontWeight: FontWeight.w600),
                    ),
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
