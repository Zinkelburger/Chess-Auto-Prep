/// Free-placement editor board.
///
/// Unlike [ChessBoardWidget] there is no legality checking: tapping applies
/// the palette tool (place/erase) and dragging moves any piece anywhere —
/// dragging off the board removes it.  All state lives in
/// [BoardEditorController]; this widget is a pure view over it.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import '../common/piece_image.dart';

class BoardEditorWidget extends StatefulWidget {
  final BoardEditorController controller;

  const BoardEditorWidget({super.key, required this.controller});

  @override
  State<BoardEditorWidget> createState() => _BoardEditorWidgetState();
}

class _BoardEditorWidgetState extends State<BoardEditorWidget> {
  // Same palette as ChessBoardWidget (private there; duplicated by design —
  // the editor may diverge visually later).
  static const Color lightSquareColor = Color(0xFFF0D9B5);
  static const Color darkSquareColor = Color(0xFFB58863);

  Square? _dragFrom;
  Piece? _draggedPiece;
  Offset? _dragPosition;
  bool _isDragging = false;
  Offset? _panStart;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant BoardEditorWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// Board is always drawn from White's perspective (editor convention).
  Square? _squareAt(Offset local, double squareSize) {
    final col = (local.dx / squareSize).floor();
    final row = (local.dy / squareSize).floor();
    if (col < 0 || col > 7 || row < 0 || row > 7) return null;
    return Square((7 - row) * 8 + col);
  }

  (double, double) _squareOrigin(Square square, double squareSize) {
    final file = square & 7;
    final rank = square >> 3;
    return (file * squareSize, (7 - rank) * squareSize);
  }

  void _onPanStart(DragStartDetails details, double squareSize) {
    _panStart = details.localPosition;
    final square = _squareAt(details.localPosition, squareSize);
    if (square == null) return;
    final piece = widget.controller.pieceAt(square);
    if (piece != null) {
      _dragFrom = square;
      _draggedPiece = piece;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_draggedPiece == null || _panStart == null) return;
    if (!_isDragging &&
        (details.localPosition - _panStart!).distance > 3) {
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
        widget.controller.removePiece(_dragFrom!); // dropped off-board
      } else if (target != _dragFrom) {
        widget.controller.movePiece(_dragFrom!, target);
      }
    } else if (!_isDragging && _panStart != null) {
      // Desktop presses usually win the pan arena; treat as a tap.
      final square = _squareAt(_panStart!, squareSize);
      if (square != null) widget.controller.tapSquare(square);
    }
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
          child: GestureDetector(
            onPanStart: (d) => _onPanStart(d, squareSize),
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => _onPanEnd(squareSize),
            onTapUp: (d) {
              if (_isDragging) return;
              final square = _squareAt(d.localPosition, squareSize);
              if (square != null) widget.controller.tapSquare(square);
            },
            child: Stack(
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
                          piece: _draggedPiece!, size: squareSize),
                    ),
                  ),
              ],
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
      final piece = widget.controller.pieceAt(square);
      if (piece == null) continue;
      if (_isDragging && square == _dragFrom) continue;
      final (x, y) = _squareOrigin(square, squareSize);
      widgets.add(Positioned(
        left: x,
        top: y,
        width: squareSize,
        height: squareSize,
        child: IgnorePointer(
          child: PieceImage(piece: piece, size: squareSize),
        ),
      ));
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
              col * squareSize, row * squareSize, squareSize, squareSize),
          Paint()..color = isLight ? lightColor : darkColor,
        );
      }
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _EditorBoardPainter old) =>
      lightColor != old.lightColor || darkColor != old.darkColor;
}
