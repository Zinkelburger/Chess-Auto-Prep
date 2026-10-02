import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/generation/legal_moves.dart';
import '../chess/pgn/tree_edit.dart';
import '../ui/theme.dart';
import '../ui/app_keys.dart';

/// A single keyboard stop and a semantic square grid over the pointer board.
/// Arrow keys follow the displayed orientation; Enter selects and plays.
class AccessibleBoard extends StatefulWidget {
  const AccessibleBoard({
    super.key,
    required this.fen,
    required this.orientation,
    required this.movable,
    required this.onMove,
    required this.child,
  });
  final Fen fen;
  final Side orientation;
  final bool movable;
  final ValueChanged<String> onMove;
  final Widget child;

  @override
  State<AccessibleBoard> createState() => _AccessibleBoardState();
}

class _AccessibleBoardState extends State<AccessibleBoard> {
  Position? _position;
  Square _cursor = Square.e1;
  Square? _from;
  bool _focused = false, _promoting = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _position = positionOf(widget.fen);
    _cursor = widget.orientation == Side.white ? Square.e1 : Square.e8;
  }

  @override
  void didUpdateWidget(AccessibleBoard old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen || old.movable != widget.movable) {
      _position = positionOf(widget.fen);
      _from = null;
      _notice = null;
    }
  }

  String _square(Square square) {
    final piece = _position?.board.pieceAt(square);
    return '${square.name}, ${piece == null ? 'empty' : '${piece.color == Side.white ? 'White' : 'Black'} ${piece.role.name}'}';
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent)
      return KeyEventResult.ignored;
    final direction = switch (event) {
      _ when AppKey.squareLeft.accepts(event) => (-1, 0),
      _ when AppKey.squareRight.accepts(event) => (1, 0),
      _ when AppKey.squareUp.accepts(event) => (0, 1),
      _ when AppKey.squareDown.accepts(event) => (0, -1),
      _ => null,
    };
    if (direction != null) {
      final sign = widget.orientation == Side.white ? 1 : -1;
      final file = (_cursor.file + direction.$1 * sign).clamp(0, 7);
      final rank = (_cursor.rank + direction.$2 * sign).clamp(0, 7);
      setState(() {
        _cursor = Square(file + rank * 8);
        _notice = null;
      });
      return KeyEventResult.handled;
    }
    if (AppKey.squareChoose.accepts(event)) {
      _activate(_cursor);
      return KeyEventResult.handled;
    }
    if (AppKey.squareClear.accepts(event) && _from != null) {
      setState(() {
        _from = null;
        _notice = 'Selection cleared';
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _activate(Square square) async {
    if (_promoting) return;
    final position = _position;
    if (position == null || !widget.movable) return;
    final from = _from;
    final moves = from == null
        ? <NamedMove>[]
        : legalMovesOf(position)
              .where(
                (move) =>
                    move.move.from == from &&
                    (move.uci.substring(2, 4) == square.name ||
                        move.move.to == square),
              )
              .toList();
    if (moves.isNotEmpty) {
      final fen = widget.fen;
      final move = moves.length == 1 ? moves.single : await _promotion(moves);
      if (!mounted || move == null || widget.fen != fen || !widget.movable)
        return;
      setState(() {
        _from = null;
        _notice = null;
      });
      widget.onMove(move.uci);
      return;
    }
    final piece = position.board.pieceAt(square);
    setState(() {
      _cursor = square;
      if (_from == square) {
        _from = null;
        _notice = 'Selection cleared';
      } else if (piece?.color == position.turn) {
        _from = square;
        _notice = '${_square(square)} selected. Choose a destination.';
      } else {
        _notice = from == null
            ? 'Choose a piece of the side to move.'
            : 'That move is not legal here.';
      }
    });
  }

  Future<NamedMove?> _promotion(List<NamedMove> moves) async {
    _promoting = true;
    try {
      return await showDialog<NamedMove>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Promote pawn'),
          children: [
            for (final move in moves)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, move),
                child: Text(move.move.promotion!.name),
              ),
          ],
        ),
      );
    } finally {
      _promoting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;
    final turn = position?.turn == Side.black ? 'Black' : 'White';
    return Focus(
      debugLabel: 'Chessboard',
      onFocusChange: (value) {
        if (mounted) setState(() => _focused = value);
      },
      onKeyEvent: _key,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: position == null
            ? 'Chessboard, position unavailable'
            : 'Chessboard, $turn to move${position.isCheck ? ', check' : ''}',
        hint: widget.movable
            ? 'Arrow keys explore squares. Enter selects a piece and its destination. Escape clears selection.'
            : 'Read-only position. Arrow keys explore squares.',
        child: LayoutBuilder(
          builder: (context, size) => Stack(
            children: [
              ExcludeSemantics(child: widget.child),
              for (var index = 0; index < 64; index++)
                _cell(context, Square(index), size.maxWidth / 8),
              if (_focused || _notice != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Semantics(
                      liveRegion: true,
                      label: _notice ?? _square(_cursor),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, Square square, double size) {
    final white = widget.orientation == Side.white;
    final active = _focused && square == _cursor;
    final selected = _from == square;
    return Positioned(
      left: (white ? square.file : 7 - square.file) * size,
      top: (white ? 7 - square.rank : square.rank) * size,
      width: size,
      height: size,
      child: Semantics(
        label: _square(square),
        selected: selected,
        button: widget.movable,
        onTap: widget.movable ? () => _activate(square) : null,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: active || selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: boardFocusWidth,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
