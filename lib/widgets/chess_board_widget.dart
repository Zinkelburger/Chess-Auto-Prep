import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:dartchess/dartchess.dart';

import '../utils/chess_utils.dart' show roleChar, parseSquare, toAlgebraic;

// ── Board annotations (arrows, circles, labels) ─────────────────────────

/// Predefined annotation brushes (color + opacity + stroke width).
enum AnnotationBrush {
  green(Color(0xCC15781B), 3.0),
  red(Color(0xCCCC2222), 3.0),
  blue(Color(0xCC003088), 3.0),
  yellow(Color(0xCCE6A800), 3.0),
  purple(Color(0xCC9B59B6), 3.0);

  final Color color;
  final double strokeWidthFactor;
  const AnnotationBrush(this.color, this.strokeWidthFactor);
}

/// A single annotation drawn on the board.
///
/// - Arrow: both [orig] and [dest] set, different squares.
/// - Circle: only [orig] set (or [dest] == [orig]).
/// - Either may carry an optional [label] rendered at the target square.
class BoardAnnotation {
  final String orig;
  final String? dest;
  final AnnotationBrush brush;
  final String? label;

  const BoardAnnotation({
    required this.orig,
    this.dest,
    this.brush = AnnotationBrush.green,
    this.label,
  });

  bool get isArrow => dest != null && dest != orig;
  bool get isCircle => !isArrow;
}

/// Rich move object that contains complete information about a move
class CompletedMove {
  final String from;
  final String to;
  final String san;
  final String fenBefore;
  final String fenAfter;
  final String uci;

  CompletedMove({
    required this.from,
    required this.to,
    required this.san,
    required this.fenBefore,
    required this.fenAfter,
    required this.uci,
  });

  @override
  String toString() => 'Move($uci -> $san, $fenBefore -> $fenAfter)';
}

/// A professional chess board widget that properly scales and handles interaction.
/// Uses a simple, maintainable approach: CustomPainter for board + SVG widgets for pieces
class ChessBoardWidget extends StatefulWidget {
  final Position position;
  final Function(CompletedMove)? onMove;
  final bool enableUserMoves;
  final bool flipped;
  final Set<String> highlightedSquares;
  final Function(String)? onSquareClicked;
  final Function(String)? onPieceSelected;
  final List<BoardAnnotation> annotations;

  const ChessBoardWidget({
    super.key,
    required this.position,
    this.onMove,
    this.enableUserMoves = true,
    this.flipped = false,
    this.highlightedSquares = const {},
    this.onSquareClicked,
    this.onPieceSelected,
    this.annotations = const [],
  });

  @override
  State<ChessBoardWidget> createState() => _ChessBoardWidgetState();
}

class _ChessBoardWidgetState extends State<ChessBoardWidget> {
  String? selectedSquare;
  final Set<String> _internalHighlights = {};

  String? _dragStartSquare;
  bool _isDragging = false;
  Offset? _dragStartPosition;
  Offset? _currentDragPosition;
  Piece? _draggedPiece;

  static const Color lightSquareColor = Color(0xFFF0D9B5);
  static const Color darkSquareColor = Color(0xFFB58863);
  static const Color selectedSquareColor = Color(0xFFFFFF00);
  static const Color highlightColor = Color(0x806496FF);

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
            onPanStart: (details) {
              if (!widget.enableUserMoves) return;
              _onPanStart(details, squareSize);
            },
            onPanUpdate: (details) {
              if (!widget.enableUserMoves) return;
              _onPanUpdate(details);
            },
            onPanEnd: (details) {
              if (!widget.enableUserMoves) return;
              _onPanEnd(details, squareSize);
            },
            onTapUp: (details) {
              if (!widget.enableUserMoves) return;
              if (!_isDragging) {
                final col = (details.localPosition.dx / squareSize).floor();
                final row = (details.localPosition.dy / squareSize).floor();
                final square = _coordsToSquare(col, row);
                _onSquareTap(square);
              }
            },
            child: Stack(
              children: [
                CustomPaint(
                  painter: _BoardPainter(
                    selectedSquare: selectedSquare,
                    highlightedSquares: {
                      ...widget.highlightedSquares,
                      ..._internalHighlights
                    },
                    flipped: widget.flipped,
                  ),
                  size: Size(boardSize, boardSize),
                ),
                ..._buildPieceWidgets(boardSize, squareSize),
                if (widget.annotations.isNotEmpty)
                  CustomPaint(
                    painter: _AnnotationPainter(
                      annotations: widget.annotations,
                      flipped: widget.flipped,
                    ),
                    size: Size(boardSize, boardSize),
                  ),
                if (_isDragging &&
                    _draggedPiece != null &&
                    _currentDragPosition != null)
                  _buildDraggedPiece(squareSize),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildPieceWidgets(double boardSize, double squareSize) {
    final pieces = <Widget>[];

    for (String file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (int rank = 1; rank <= 8; rank++) {
        final squareName = '$file$rank';
        final sq = parseSquare(squareName);
        if (sq == null) continue;
        final piece = widget.position.board.pieceAt(sq);

        if (piece != null) {
          if (_isDragging && squareName == _dragStartSquare) {
            continue;
          }

          final (col, row) = _squareToCoords(squareName);
          final x = col * squareSize;
          final y = row * squareSize;

          pieces.add(
            Positioned(
              left: x,
              top: y,
              width: squareSize,
              height: squareSize,
              child: IgnorePointer(
                child: _PieceWidget(
                  piece: piece,
                  size: squareSize,
                ),
              ),
            ),
          );
        }
      }
    }

    return pieces;
  }

  (int, int) _squareToCoords(String square) {
    return _BoardPainter._squareToCoords(square, widget.flipped);
  }

  String _coordsToSquare(int col, int row) {
    final file = widget.flipped ? (7 - col) : col;
    final rank = widget.flipped ? row : (7 - row);

    return String.fromCharCode(97 + file) + (rank + 1).toString();
  }

  void _onPanStart(DragStartDetails details, double squareSize) {
    final col = (details.localPosition.dx / squareSize).floor();
    final row = (details.localPosition.dy / squareSize).floor();
    final square = _coordsToSquare(col, row);

    final sq = parseSquare(square);
    if (sq == null) return;
    final piece = widget.position.board.pieceAt(sq);
    if (piece != null && piece.color == widget.position.turn) {
      final hasLegalMoves = widget.position.legalMoves[sq]?.isNotEmpty ?? false;

      if (hasLegalMoves) {
        setState(() {
          _dragStartSquare = square;
          _dragStartPosition = details.localPosition;
          _draggedPiece = piece;
          selectedSquare = square;
          _highlightLegalMoves(square);
        });
        widget.onPieceSelected?.call(square);
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragStartSquare != null && _dragStartPosition != null) {
      final distance = (details.localPosition - _dragStartPosition!).distance;

      if (!_isDragging && distance > 3) {
        setState(() {
          _isDragging = true;
        });
      }

      if (_isDragging) {
        setState(() {
          _currentDragPosition = details.localPosition;
        });
      }
    }
  }

  void _onPanEnd(DragEndDetails details, double squareSize) {
    if (_isDragging &&
        _dragStartSquare != null &&
        _currentDragPosition != null) {
      final col = (_currentDragPosition!.dx / squareSize).floor();
      final row = (_currentDragPosition!.dy / squareSize).floor();

      if (col >= 0 && col < 8 && row >= 0 && row < 8) {
        final endSquare = _coordsToSquare(col, row);
        if (endSquare != _dragStartSquare) {
          _tryMakeMove(_dragStartSquare!, endSquare);
        }
      }
    }

    _resetDragState();
  }

  void _resetDragState() {
    setState(() {
      _dragStartSquare = null;
      _isDragging = false;
      _dragStartPosition = null;
      _currentDragPosition = null;
      _draggedPiece = null;
      selectedSquare = null;
      _internalHighlights.clear();
    });
  }

  void _onSquareTap(String square) {
    widget.onSquareClicked?.call(square);

    if (selectedSquare == null) {
      final sq = parseSquare(square);
      if (sq == null) return;
      final piece = widget.position.board.pieceAt(sq);
      if (piece != null && piece.color == widget.position.turn) {
        setState(() {
          selectedSquare = square;
          _highlightLegalMoves(square);
        });
        widget.onPieceSelected?.call(square);
      }
    } else {
      if (selectedSquare == square) {
        setState(() {
          selectedSquare = null;
          _internalHighlights.clear();
        });
      } else {
        _tryMakeMove(selectedSquare!, square);
      }
    }
  }

  void _highlightLegalMoves(String fromSquare) {
    _internalHighlights.clear();

    final fromSq = parseSquare(fromSquare);
    if (fromSq == null) return;

    final targets = widget.position.legalMoves[fromSq];
    if (targets == null) return;

    final piece = widget.position.board.pieceAt(fromSq);
    final isKing = piece?.role == Role.king;

    for (final toSq in targets.squares) {
      if (isKing) {
        final mapped = _castlingKingDest(fromSq, toSq);
        _internalHighlights.add(toAlgebraic(mapped));
      } else {
        _internalHighlights.add(toAlgebraic(toSq));
      }
    }
  }

  /// Dartchess encodes castling as king→rook-square. Map to king destination.
  Square _castlingKingDest(Square from, Square to) {
    final diff = (to - from).abs();
    if (diff <= 2) return to; // normal king move, not castling
    // Kingside: rook on h-file → king lands on g-file
    if (to > from) return Square(from + 2);
    // Queenside: rook on a-file → king lands on c-file
    return Square(from - 2);
  }

  /// Reverse map: if user clicks the king destination, return the rook square
  /// that dartchess expects for castling.
  Square? _reverseCastlingTarget(Square from, Square clickedTo) {
    final piece = widget.position.board.pieceAt(from);
    if (piece?.role != Role.king) return null;

    final targets = widget.position.legalMoves[from];
    if (targets == null) return null;

    for (final legalTo in targets.squares) {
      if (_castlingKingDest(from, legalTo) == clickedTo && legalTo != clickedTo) {
        return legalTo;
      }
    }
    return null;
  }

  Widget _buildDraggedPiece(double squareSize) {
    if (_draggedPiece == null || _currentDragPosition == null) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: _currentDragPosition!.dx - squareSize / 2,
      top: _currentDragPosition!.dy - squareSize / 2,
      child: IgnorePointer(
        child: _PieceWidget(
          piece: _draggedPiece!,
          size: squareSize,
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ChessBoardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.position != oldWidget.position ||
        widget.flipped != oldWidget.flipped) {
      _resetDragState();
    }
  }

  void _tryMakeMove(String from, String to) {
    try {
      final fenBefore = widget.position.fen;

      final fromSq = parseSquare(from);
      var toSq = parseSquare(to);
      if (fromSq == null || toSq == null) {
        _clearSelection();
        return;
      }

      // Check if there are legal moves from this square to the target
      final targets = widget.position.legalMoves[fromSq];
      if (targets == null || !targets.has(toSq)) {
        // User may have clicked the king destination; map back to rook square
        final castlingTarget = _reverseCastlingTarget(fromSq, toSq);
        if (castlingTarget != null) {
          toSq = castlingTarget;
        } else {
          _clearSelection();
          return;
        }
      }

      final piece = widget.position.board.pieceAt(fromSq);
      final isPromotion = piece?.role == Role.pawn &&
          ((piece!.color == Side.white && toSq ~/ 8 == 7) ||
              (piece.color == Side.black && toSq ~/ 8 == 0));

      final move = NormalMove(
        from: fromSq,
        to: toSq,
        promotion: isPromotion ? Role.queen : null,
      );

      final (newPosition, san) = widget.position.makeSan(move);
      final fenAfter = newPosition.fen;
      final uci = isPromotion ? '$from${to}q' : '$from$to';

      _clearSelection();

      widget.onMove?.call(CompletedMove(
        from: from,
        to: to,
        san: san,
        fenBefore: fenBefore,
        fenAfter: fenAfter,
        uci: uci,
      ));
    } catch (e) {
      _clearSelection();
    }
  }

  void _clearSelection() {
    setState(() {
      selectedSquare = null;
      _internalHighlights.clear();
    });
  }
}

/// Simple piece widget that renders SVG pieces
class _PieceWidget extends StatelessWidget {
  final Piece piece;
  final double size;

  const _PieceWidget({
    required this.piece,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final color = piece.color == Side.white ? 'w' : 'b';
    final type = roleChar(piece.role);
    final assetPath = 'assets/pieces/$color$type.svg';

    return Center(
      child: SvgPicture.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// Custom painter for board squares and highlights only
class _BoardPainter extends CustomPainter {
  final String? selectedSquare;
  final Set<String> highlightedSquares;
  final bool flipped;

  _BoardPainter({
    required this.selectedSquare,
    required this.highlightedSquares,
    required this.flipped,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final squareSize = size.width / 8;

    for (String file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (int rank = 1; rank <= 8; rank++) {
        final square = '$file$rank';

        final (col, row) = _squareToCoords(square, flipped);
        final x = col * squareSize;
        final y = row * squareSize;

        final fileIndex = file.codeUnitAt(0) - 97;
        final rankIndex = rank - 1;
        final isLightSquare = (fileIndex + rankIndex) % 2 != 0;

        final Color color;
        if (square == selectedSquare) {
          color = _ChessBoardWidgetState.selectedSquareColor;
        } else {
          color = isLightSquare
              ? _ChessBoardWidgetState.lightSquareColor
              : _ChessBoardWidgetState.darkSquareColor;
        }

        final rect = Rect.fromLTWH(x, y, squareSize, squareSize);
        canvas.drawRect(rect, Paint()..color = color);

        if (highlightedSquares.contains(square) && square != selectedSquare) {
          canvas.drawRect(
              rect,
              Paint()
                ..color = _ChessBoardWidgetState.highlightColor
                ..blendMode = BlendMode.multiply);
        }
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

  static (int, int) _squareToCoords(String square, bool flipped) {
    final file = square.codeUnitAt(0) - 97;
    final rank = int.parse(square[1]) - 1;

    final col = flipped ? (7 - file) : file;
    final row = flipped ? rank : (7 - rank);

    return (col, row);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Paints arrows, circles, and labels on top of the board and pieces.
class _AnnotationPainter extends CustomPainter {
  final List<BoardAnnotation> annotations;
  final bool flipped;

  _AnnotationPainter({required this.annotations, required this.flipped});

  @override
  void paint(Canvas canvas, Size size) {
    final sq = size.width / 8;

    for (final a in annotations) {
      if (a.isArrow) {
        _drawArrow(canvas, sq, a);
      } else {
        _drawCircle(canvas, sq, a);
      }
      if (a.label != null) {
        _drawLabel(canvas, sq, a);
      }
    }
  }

  Offset _center(String square, double sq) {
    final (col, row) = _BoardPainter._squareToCoords(square, flipped);
    return Offset((col + 0.5) * sq, (row + 0.5) * sq);
  }

  void _drawArrow(Canvas canvas, double sq, BoardAnnotation a) {
    final from = _center(a.orig, sq);
    final to = _center(a.dest!, sq);
    final delta = to - from;
    final dist = delta.distance;
    if (dist < 1) return;

    final strokeW = sq * 0.15 * a.brush.strokeWidthFactor / 3.0;
    final headLen = sq * 0.35;
    final headHalfW = sq * 0.22;

    final dir = delta / dist;
    final perp = Offset(-dir.dy, dir.dx);

    // Shorten arrow so the head doesn't overshoot the center
    final shaftEnd = to - dir * headLen;

    final paint = Paint()
      ..color = a.brush.color
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Shaft
    canvas.drawLine(from, shaftEnd, paint);

    // Arrowhead (filled triangle)
    final headPath = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(shaftEnd.dx + perp.dx * headHalfW,
          shaftEnd.dy + perp.dy * headHalfW)
      ..lineTo(shaftEnd.dx - perp.dx * headHalfW,
          shaftEnd.dy - perp.dy * headHalfW)
      ..close();

    canvas.drawPath(
        headPath,
        Paint()
          ..color = a.brush.color
          ..style = PaintingStyle.fill);
  }

  void _drawCircle(Canvas canvas, double sq, BoardAnnotation a) {
    final center = _center(a.orig, sq);
    final radius = sq * 0.42;
    final strokeW = sq * 0.06 * a.brush.strokeWidthFactor / 3.0;

    canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = a.brush.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(strokeW, 2.0));
  }

  void _drawLabel(Canvas canvas, double sq, BoardAnnotation a) {
    final target = a.isArrow ? a.dest! : a.orig;
    final center = _center(target, sq);
    // Offset label to top-right corner of the square
    final pos = Offset(center.dx + sq * 0.25, center.dy - sq * 0.25);
    final radius = sq * 0.17;

    // Background circle
    canvas.drawCircle(
        pos,
        radius,
        Paint()
          ..color = a.brush.color
          ..style = PaintingStyle.fill);

    // Text
    final tp = TextPainter(
      text: TextSpan(
        text: a.label,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 1.1,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) =>
      annotations != old.annotations || flipped != old.flipped;
}
