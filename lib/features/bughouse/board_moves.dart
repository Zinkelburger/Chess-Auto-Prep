import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_line.dart';
import '../../ui/action_context_menu.dart';
import '../../ui/app_action.dart';
import '../../ui/app_keys.dart';
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';

/// A board's moves read like the workspace's move list: its main line as
/// running text, each variation an indented block right after the move it
/// replaces, hand edits in muted ink where they were made. Clicking a move
/// puts the board there; the four step buttons are under it. The list takes
/// the height its parent leaves.
class BoardMoves extends StatelessWidget {
  const BoardMoves({super.key, required this.lab, required this.board});

  final BughouseLab lab;
  final BoardNumber board;

  @override
  Widget build(BuildContext context) {
    final line = lab.line;
    final at = line.at(board);
    final ahead = line.mainChild(board, at) != null;
    final scheme = Theme.of(context).colorScheme;
    final focused = lab.focus == board && !lab.single;
    final list = Container(
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(
            color: focused ? scheme.primary : scheme.outline,
          ),
        ),
      ),
      child: _MoveText(lab: lab, board: board),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: list),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            _step(
              Icons.first_page,
              AppKey.firstMove.tip('First move'),
              at != null,
              () => lab.goTo(board, null),
            ),
            _step(
              Icons.chevron_left,
              AppKey.stepBack.tip('Back'),
              at != null,
              () => lab.stepOn(board, -1),
            ),
            _step(
              Icons.chevron_right,
              AppKey.stepForward.tip('Forward'),
              ahead,
              () => lab.stepOn(board, 1),
            ),
            _step(
              Icons.last_page,
              AppKey.lastMove.tip('Last move'),
              ahead,
              () => lab.goTo(board, line.lineOf(board).last),
            ),
          ],
        ),
      ],
    );
  }

  Widget _step(IconData icon, String tip, bool enabled, VoidCallback go) =>
      IconButton(
        icon: Icon(icon, size: IconSize.action),
        tooltip: lab.single ? tip : '$tip, ${board.label.toLowerCase()}',
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? go : null,
      );
}

/// The board's tree of lines as text, scrolled so the move it is at shows.
class _MoveText extends StatelessWidget {
  const _MoveText({required this.lab, required this.board});

  final BughouseLab lab;
  final BoardNumber board;

  @override
  Widget build(BuildContext context) {
    final line = lab.line;
    final first = line.children(board, null);
    if (first.isEmpty) return const SizedBox.expand();
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: Space.s),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _Lines(lab, board).line(first),
        ),
      ),
    );
  }
}

/// Lays a board's lines out as the workspace's move list does.
final class _Lines {
  _Lines(this.lab, this.board);

  final BughouseLab lab;
  final BoardNumber board;

  TableLine get _line => lab.line;

  /// The line that starts at `siblings[branch]` and follows main
  /// continuations to the end. The other siblings of a main move are its
  /// variations and interrupt the line as indented blocks, each a line of
  /// its own; the siblings of a variation's first move are not repeated.
  List<Widget> line(List<int> siblings, {int branch = 0}) {
    final blocks = <Widget>[];
    var tokens = <Widget>[];
    var numbered = true;
    void breakRow() {
      if (tokens.isNotEmpty) blocks.add(_Row(tokens));
      tokens = <Widget>[];
      numbered = true;
    }

    var at = (siblings: siblings, branch: branch);
    while (true) {
      final node = at.siblings[at.branch];
      switch (_line.entry(node)) {
        case final LineMove move:
          tokens.add(_token(node, _label(move, numbered), move.san));
          numbered = false;
        case HandEdit(:final changes):
          tokens.add(_token(node, '', handChangeText(changes), edit: true));
          // The move after a note shows its number again, as in print.
          numbered = true;
      }
      if (at.branch == 0 && at.siblings.length > 1) {
        breakRow();
        for (var b = 1; b < at.siblings.length; b++) {
          blocks.add(_Variation(children: line(at.siblings, branch: b)));
        }
      }
      final next = _line.children(board, node);
      if (next.isEmpty) break;
      at = (siblings: next, branch: 0);
    }
    breakRow();
    return blocks;
  }

  static String _label(LineMove move, bool startsLine) =>
      move.side == Side.white
      ? '${move.number}.'
      : startsLine
      ? '${move.number}...'
      : '';

  Widget _token(int node, String label, String text, {bool edit = false}) =>
      _MoveToken(
        label: label,
        text: text,
        edit: edit,
        tip: switch (_line.entry(node)) {
          LineMove(:final side) => 'Player ${Seat.of(board, side).letter}',
          HandEdit() => 'Hands edited',
        },
        selected: _line.at(board) == node,
        onTap: () => lab.goTo(board, node),
        menu: () => moveMenu(lab, node),
      );
}

/// A row of moves that wrap as text does.
class _Row extends StatelessWidget {
  const _Row(this.tokens);

  final List<Widget> tokens;

  @override
  Widget build(BuildContext context) =>
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: tokens);
}

class _Variation extends StatelessWidget {
  const _Variation({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: Space.xs),
    padding: const EdgeInsets.only(left: variationIndent),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: Theme.of(context).colorScheme.outline),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );
}

/// What a move or hand edit in a board's list offers on the right button,
/// as the workspace's move list does: its variation promoted or made the
/// main line, taking it out with what follows, the line up to it as PGN
/// (crazyhouse with one board, BPGN with two), the board's FEN after it
/// and, with two boards, the dual FEN.
List<AppAction> moveMenu(BughouseLab lab, int node) {
  final line = lab.line;
  final main = line.isMain(node);
  final after = lab.positionAfter(node);
  final board = line.nodes[node].board;
  return [
    AppAction(
      'Promote variation',
      main ? null : () => lab.promote(node),
      icon: Icons.arrow_upward,
    ),
    AppAction(
      'Make main line',
      main ? null : () => lab.makeMainLine(node),
      icon: Icons.check,
    ),
    AppAction(
      'Delete from here',
      () => lab.deleteFrom(node),
      icon: Icons.delete_outline,
    ),
    AppAction(
      'Copy line PGN',
      () => _copy(lab.linePgnThrough(node)),
      icon: Icons.content_copy,
    ),
    AppAction(
      'Copy FEN',
      after == null ? null : () => _copy(after.board(board).fen),
      icon: Icons.content_copy,
    ),
    if (!lab.single)
      AppAction(
        'Copy dual FEN',
        after == null ? null : () => _copy(after.dualFen),
        icon: Icons.content_copy,
      ),
  ];
}

void _copy(String text) =>
    unawaited(Clipboard.setData(ClipboardData(text: text)));

/// One clickable move or hand edit, with what can be done to it on the
/// right button. When it becomes the selected one it scrolls into view.
class _MoveToken extends StatefulWidget {
  const _MoveToken({
    required this.label,
    required this.text,
    required this.edit,
    required this.tip,
    required this.selected,
    required this.onTap,
    required this.menu,
  });

  final String label;
  final String text;

  /// A hand edit, in muted ink.
  final bool edit;
  final String tip;
  final bool selected;
  final VoidCallback onTap;
  final List<AppAction> Function() menu;

  @override
  State<_MoveToken> createState() => _MoveTokenState();
}

class _MoveTokenState extends State<_MoveToken> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(_MoveToken old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  /// After the frame, because the token has no position until it is laid
  /// out.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 100),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tip,
      waitDuration: previewDelay,
      child: Semantics(
        selected: widget.selected,
        child: InkWell(
          onTap: widget.onTap,
          onSecondaryTapUp: (details) => unawaited(
            showActionContextMenu(
              context,
              details.globalPosition,
              widget.menu(),
            ),
          ),
          borderRadius: BorderRadius.circular(3),
          child: Container(
            padding: moveTokenPadding,
            decoration: BoxDecoration(
              color: widget.selected
                  ? scheme.primary.withValues(alpha: 0.35)
                  : null,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  if (widget.label.isNotEmpty)
                    TextSpan(
                      text: '${widget.label} ',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  TextSpan(
                    text: widget.edit
                        ? widget.text
                        : displaySan(context, widget.text),
                  ),
                ],
              ),
              softWrap: false,
              overflow: TextOverflow.clip,
              style: readingMoveText.copyWith(
                color: widget.edit ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
