/// Free-placement editor board, after the lichess editor.
///
/// There is no legality checking. What the pointer does depends on the
/// [EditorTool] in hand:
///
///   * pointer — press a piece and drag it anywhere; dropping it off the
///     board removes it. A bare click does nothing.
///   * brush — a press places the piece (a press on a square that already
///     holds that piece removes it), and keeping the button down paints the
///     piece over every square the pointer crosses.
///   * eraser — the same stroke, clearing squares.
///
/// A right-click is passed up as [onSecondaryPress]; the owner decides what
/// it means. Palette pieces dropped onto the board arrive through [onPlace].
/// Flutter cannot show a piece as the mouse cursor the way lichess does, so
/// while a brush or the eraser is in hand the cursor is hidden over the
/// board and a ghost of the tool follows the pointer instead. Position
/// changes are passed to the owning controller; this widget owns only the
/// active stroke.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import '../../theme/app_colors.dart';
import '../common/piece_image.dart';

class EditableBoard extends StatefulWidget {
  const EditableBoard({
    super.key,
    required this.pieceAt,
    required this.tool,
    required this.onPress,
    required this.onPaint,
    required this.onSecondaryPress,
    required this.onRemove,
    required this.onMove,
    required this.onPlace,
    this.flipped = false,
  });

  final Piece? Function(Square) pieceAt;
  final EditorTool tool;

  /// Primary button went down on a square while a brush or the eraser is in
  /// hand.
  final ValueChanged<Square> onPress;

  /// The held pointer crossed onto a new square during a brush/eraser stroke.
  final ValueChanged<Square> onPaint;

  /// Secondary (right) button on a square, whatever the tool.
  final ValueChanged<Square> onSecondaryPress;

  /// A piece was dragged off the board.
  final ValueChanged<Square> onRemove;

  /// A piece was dragged from one square to another (pointer tool).
  final void Function(Square, Square) onMove;

  /// A palette piece was dropped on a square.
  final void Function(Square, Piece) onPlace;
  final bool flipped;

  @override
  State<EditableBoard> createState() => _EditableBoardState();
}

class _EditableBoardState extends State<EditableBoard> {
  // Same palette as ChessBoardWidget, both sourced from the shared board
  // tokens (the editor may still diverge visually later).
  static const Color lightSquareColor = AppColors.boardLightSquare;
  static const Color darkSquareColor = AppColors.boardDarkSquare;

  // Pointer-tool drag of a piece already on the board.
  Square? _dragFrom;
  Piece? _draggedPiece;
  Offset? _dragPosition;
  bool _isDragging = false;
  Offset? _panStart;

  // Brush/eraser stroke. A stroke that began by lifting the brush's own piece
  // off a square must not start painting it back the moment the pointer
  // moves, so that press deletes and then the stroke is inert.
  bool _painting = false;
  bool _deleteStroke = false;
  Square? _lastPainted;

  /// Where the pointer is while hovering, for the tool ghost.
  Offset? _hover;

  bool get _paints => widget.tool is PieceBrush || widget.tool is EraserTool;

  /// Map pointer coordinates to either board orientation.
  Square? _squareAt(Offset local, double squareSize) {
    final col = (local.dx / squareSize).floor();
    final row = (local.dy / squareSize).floor();
    if (col < 0 || col > 7 || row < 0 || row > 7) return null;
    return widget.flipped
        ? Square(row * 8 + 7 - col)
        : Square((7 - row) * 8 + col);
  }

  (double, double) _squareOrigin(Square square, double squareSize) {
    final file = square & 7;
    final rank = square >> 3;
    return widget.flipped
        ? ((7 - file) * squareSize, rank * squareSize)
        : (file * squareSize, (7 - rank) * squareSize);
  }

  /// Every stroke starts here, on the press itself rather than on release:
  /// that is what lets a held button paint, and it is what lichess does.
  void _onPanDown(DragDownDetails details, double squareSize) {
    _panStart = details.localPosition;
    final square = _squareAt(details.localPosition, squareSize);
    if (square == null) return;
    if (_paints) {
      final tool = widget.tool;
      _deleteStroke =
          tool is PieceBrush && widget.pieceAt(square) == tool.piece;
      _painting = true;
      _lastPainted = square;
      widget.onPress(square);
      return;
    }
    final piece = widget.pieceAt(square);
    if (piece != null) {
      _dragFrom = square;
      _draggedPiece = piece;
    }
  }

  void _onPanUpdate(DragUpdateDetails details, double squareSize) {
    if (!mounted) return;
    if (_painting) {
      _hover = details.localPosition;
      final square = _squareAt(details.localPosition, squareSize);
      if (!_deleteStroke && square != null && square != _lastPainted) {
        _lastPainted = square;
        widget.onPaint(square);
      } else {
        setState(() {});
      }
      return;
    }
    if (_draggedPiece == null || _panStart == null) return;
    if (!_isDragging && (details.localPosition - _panStart!).distance > 3) {
      _isDragging = true;
    }
    if (_isDragging) {
      setState(() => _dragPosition = details.localPosition);
    }
  }

  void _onPanEnd(double squareSize) {
    if (_isDragging && _dragFrom != null && _dragPosition != null) {
      final target = _squareAt(_dragPosition!, squareSize);
      if (target == null) {
        widget.onRemove(_dragFrom!); // dropped off-board
      } else if (target != _dragFrom) {
        widget.onMove(_dragFrom!, target);
      }
    }
    if (!mounted) return;
    setState(_clearStroke);
  }

  void _clearStroke() {
    _dragFrom = null;
    _draggedPiece = null;
    _dragPosition = null;
    _isDragging = false;
    _panStart = null;
    _painting = false;
    _deleteStroke = false;
    _lastPainted = null;
  }

  MouseCursor _cursor(double squareSize) {
    if (_paints) return SystemMouseCursors.none;
    if (_isDragging) return SystemMouseCursors.grabbing;
    final hover = _hover;
    if (hover != null) {
      final square = _squareAt(hover, squareSize);
      if (square != null && widget.pieceAt(square) != null) {
        return SystemMouseCursors.grab;
      }
    }
    return SystemMouseCursors.basic;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boardSize = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        final squareSize = boardSize / 8;

        return SizedBox(
          width: boardSize,
          height: boardSize,
          child: DragTarget<Piece>(
            onAcceptWithDetails: (details) {
              if (!mounted) return;
              final box = context.findRenderObject() as RenderBox;
              final square = _squareAt(
                box.globalToLocal(details.offset),
                squareSize,
              );
              if (square != null) widget.onPlace(square, details.data);
            },
            builder: (context, _, _) => MouseRegion(
              cursor: _cursor(squareSize),
              onHover: (event) {
                if (!mounted) return;
                setState(() => _hover = event.localPosition);
              },
              onExit: (_) {
                if (!mounted) return;
                setState(() => _hover = null);
              },
              child: GestureDetector(
                // A pan, not a raw pointer listener: the bughouse boards live
                // in a scrolling column, and the pan is what keeps a stroke
                // across the board from scrolling the page instead.
                dragStartBehavior: DragStartBehavior.down,
                onSecondaryTapDown: (d) {
                  if (!mounted) return;
                  final square = _squareAt(d.localPosition, squareSize);
                  if (square != null) widget.onSecondaryPress(square);
                },
                onPanCancel: () {
                  if (mounted) setState(_clearStroke);
                },
                onPanDown: (d) => _onPanDown(d, squareSize),
                onPanUpdate: (d) => _onPanUpdate(d, squareSize),
                onPanEnd: (_) => _onPanEnd(squareSize),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomPaint(
                      painter: _EditorBoardPainter(
                        lightColor: lightSquareColor,
                        darkColor: darkSquareColor,
                      ),
                      size: Size(boardSize, boardSize),
                    ),
                    ..._buildPieces(squareSize),
                    if (_isDragging &&
                        _draggedPiece != null &&
                        _dragPosition != null)
                      Positioned(
                        left: _dragPosition!.dx - squareSize / 2,
                        top: _dragPosition!.dy - squareSize / 2,
                        child: IgnorePointer(
                          child: PieceImage(
                            piece: _draggedPiece!,
                            size: squareSize,
                          ),
                        ),
                      ),
                    ?_toolGhost(squareSize),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The tool in hand, drawn where the cursor would be. Smaller than a
  /// square so the piece underneath stays readable, the way a cursor image
  /// never covers what it points at.
  Widget? _toolGhost(double squareSize) {
    final at = _hover;
    if (at == null || !_paints) return null;
    final size = squareSize * 0.8;
    final Widget ghost = switch (widget.tool) {
      PieceBrush(:final piece) => PieceImage(piece: piece, size: size),
      EraserTool() => Icon(
        Icons.delete_outline,
        size: size * 0.7,
        color: AppColors.ink,
        shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
      ),
      PointerTool() => const SizedBox.shrink(),
    };
    return Positioned(
      left: at.dx - size / 2,
      top: at.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: Opacity(opacity: 0.85, child: Center(child: ghost)),
      ),
    );
  }

  List<Widget> _buildPieces(double squareSize) {
    final widgets = <Widget>[];
    for (int i = 0; i < 64; i++) {
      final square = Square(i);
      final piece = widget.pieceAt(square);
      if (piece == null) continue;
      if (_isDragging && square == _dragFrom) continue;
      final (x, y) = _squareOrigin(square, squareSize);
      widgets.add(
        Positioned(
          left: x,
          top: y,
          width: squareSize,
          height: squareSize,
          child: IgnorePointer(
            child: PieceImage(piece: piece, size: squareSize),
          ),
        ),
      );
    }
    return widgets;
  }
}

class _EditorBoardPainter extends CustomPainter {
  final Color lightColor;
  final Color darkColor;

  _EditorBoardPainter({required this.lightColor, required this.darkColor});

  @override
  void paint(Canvas canvas, Size size) {
    final squareSize = size.width / 8;
    for (int col = 0; col < 8; col++) {
      for (int row = 0; row < 8; row++) {
        final isLight = (col + row) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(
            col * squareSize,
            row * squareSize,
            squareSize,
            squareSize,
          ),
          Paint()..color = isLight ? lightColor : darkColor,
        );
      }
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = AppColors.boardOutline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _EditorBoardPainter old) =>
      lightColor != old.lightColor || darkColor != old.darkColor;
}
