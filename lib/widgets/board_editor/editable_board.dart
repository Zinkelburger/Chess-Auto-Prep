/// Free-placement editor board.
///
/// Unlike [ChessBoardWidget] there is no legality checking: tapping applies
/// the palette tool (place/erase) and dragging moves any piece anywhere —
/// dragging off the board removes it. Position changes are passed to the
/// owning controller; this widget owns only the active drag.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../theme/app_colors.dart';
import '../common/piece_image.dart';

class EditableBoard extends StatefulWidget {
  const EditableBoard({
    super.key,
    required this.pieceAt,
    required this.onTap,
    required this.onRemove,
    required this.onMove,
    required this.onPlace,
    this.flipped = false,
  });
  final Piece? Function(Square) pieceAt;
  final ValueChanged<Square> onTap;
  final ValueChanged<Square> onRemove;
  final void Function(Square, Square) onMove;
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

  Square? _dragFrom;
  Piece? _draggedPiece;
  Offset? _dragPosition;
  bool _isDragging = false;
  Offset? _panStart;

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

  void _onPanStart(DragStartDetails details, double squareSize) {
    _panStart = details.localPosition;
    final square = _squareAt(details.localPosition, squareSize);
    if (square == null) return;
    final piece = widget.pieceAt(square);
    if (piece != null) {
      _dragFrom = square;
      _draggedPiece = piece;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!mounted) return;
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
    } else if (!_isDragging && _panStart != null) {
      // Desktop presses usually win the pan arena; treat as a tap.
      final square = _squareAt(_panStart!, squareSize);
      if (square != null) widget.onTap(square);
    }
    if (!mounted) return;
    setState(_clearDrag);
  }

  void _clearDrag() {
    _dragFrom = null;
    _draggedPiece = null;
    _dragPosition = null;
    _isDragging = false;
    _panStart = null;
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
            builder: (context, _, _) => GestureDetector(
              dragStartBehavior: DragStartBehavior.down,
              onSecondaryTapUp: (d) {
                if (!mounted) return;
                final square = _squareAt(d.localPosition, squareSize);
                if (square != null) widget.onRemove(square);
              },
              onPanCancel: () {
                if (mounted) setState(_clearDrag);
              },
              onPanStart: (d) => _onPanStart(d, squareSize),
              onPanUpdate: _onPanUpdate,
              onPanEnd: (_) => _onPanEnd(squareSize),
              onTapUp: (d) {
                if (_isDragging) return;
                final square = _squareAt(d.localPosition, squareSize);
                if (square != null) widget.onTap(square);
              },
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
                ],
              ),
            ),
          ),
        );
      },
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
