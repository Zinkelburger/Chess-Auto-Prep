import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:dartchess/dartchess.dart';

import '../models/completed_move.dart';
import '../theme/app_colors.dart';
import '../utils/chess_utils.dart'
    show parseSquare, toAlgebraic, castlingKingDestination;
import 'common/piece_image.dart';

export '../models/completed_move.dart' show CompletedMove;

// ── Board annotations (arrows, circles, labels) ─────────────────────────

/// Predefined annotation brushes (color + opacity + stroke width).
enum AnnotationBrush {
  green(AppColors.boardArrowGreen, 3.0),
  red(AppColors.boardArrowRed, 3.0),
  blue(AppColors.boardArrowBlue, 3.0),
  yellow(AppColors.boardArrowYellow, 3.0),
  purple(AppColors.boardArrowPurple, 3.0);

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

/// A professional chess board widget that properly scales and handles interaction.
/// Uses a simple, maintainable approach: CustomPainter for board + SVG widgets for pieces
class ChessBoardWidget extends StatefulWidget {
  final Position position;
  final Function(CompletedMove)? onMove;
  final bool enableUserMoves;
  final bool flipped;
  final Set<String> highlightedSquares;

  /// From/to squares of the most recent half-moves, kept subtly tinted
  /// (Chessable-style trail). Quieter than [highlightedSquares].
  final Set<String> recentMoveSquares;
  final Function(String)? onSquareClicked;
  final Function(String)? onPieceSelected;
  final List<BoardAnnotation> annotations;

  /// Right-drag finished: [orig] is where the drag started, [dest] where it
  /// ended, or null when it began and ended on the same square (a circle).
  /// Setting this is what enables shape drawing at all.
  final void Function(String orig, String? dest)? onShapeDrawn;

  const ChessBoardWidget({
    super.key,
    required this.position,
    this.onMove,
    this.enableUserMoves = true,
    this.flipped = false,
    this.highlightedSquares = const {},
    this.recentMoveSquares = const {},
    this.onSquareClicked,
    this.onPieceSelected,
    this.annotations = const [],
    this.onShapeDrawn,
  });

  @override
  State<ChessBoardWidget> createState() => _ChessBoardWidgetState();
}

class _ChessBoardWidgetState extends State<ChessBoardWidget> {
  String? selectedSquare;
  final Set<String> _internalHighlights = {};

  /// Identity of each piece across position changes, keyed by its current
  /// square. [AnimatedPositioned] slides a piece from its old square to its
  /// new one only if the widget keeps the same key across the change; this
  /// map is what turns "the knight that was on g1 is now on f3" into "widget
  /// #7 moved". Rebuilt wholesale (fresh ids, so no slide) on flips and on
  /// position jumps bigger than one move.
  final Map<String, int> _pieceIds = {};
  int _nextPieceId = 0;

  /// From/to of a move the user just played by dragging. The dropped piece is
  /// already under the cursor at its destination — sliding it there from its
  /// origin would replay the drag — so that one piece gets a fresh id and
  /// renders in place. Click-click, typed and programmatic moves all animate.
  (String, String)? _instantMove;

  static const _moveAnimationDuration = Duration(milliseconds: 180);

  String? _dragStartSquare;

  /// Square a right-button drag started on, while it is in progress.
  String? _shapeStartSquare;

  bool _isDragging = false;
  Offset? _dragStartPosition;
  Piece? _draggedPiece;

  // Drives only the floating dragged-piece layer. Following the cursor now
  // repaints one Positioned widget via ValueListenableBuilder instead of
  // setState-rebuilding the whole board (64-square painter + up to 32 piece
  // widgets) on every pointer-move event.
  final ValueNotifier<Offset?> _currentDragPosition = ValueNotifier(null);

  static const Color lightSquareColor = AppColors.boardLightSquare;
  static const Color darkSquareColor = AppColors.boardDarkSquare;
  static const Color selectedSquareColor = AppColors.boardSelected;
  static const Color highlightColor = AppColors.boardHighlight;
  static const Color recentMoveColor = AppColors.boardRecentMove;

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
          // Right-drag draws arrows and circles. It rides on a Listener rather
          // than the GestureDetector below because the pan recognizer only
          // accepts the primary button, so the two never contend.
          child: Listener(
            onPointerDown: (event) {
              if (widget.onShapeDrawn == null) return;
              if (event.buttons != kSecondaryButton) return;
              _shapeStartSquare = _squareAt(event.localPosition, squareSize);
            },
            onPointerUp: (event) {
              final start = _shapeStartSquare;
              if (start == null) return;
              _shapeStartSquare = null;
              final end = _squareAt(event.localPosition, squareSize);
              widget.onShapeDrawn?.call(start, end == start ? null : end);
            },
            onPointerCancel: (_) => _shapeStartSquare = null,
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
                        ..._internalHighlights,
                      },
                      recentMoveSquares: widget.recentMoveSquares,
                      flipped: widget.flipped,
                      lightColor: lightSquareColor,
                      darkColor: darkSquareColor,
                      selectColor: selectedSquareColor,
                      highlightColor: highlightColor,
                      recentMoveColor: recentMoveColor,
                    ),
                    size: Size(boardSize, boardSize),
                  ),
                  ..._buildPieceWidgets(squareSize),
                  if (widget.annotations.isNotEmpty)
                    CustomPaint(
                      painter: _AnnotationPainter(
                        annotations: widget.annotations,
                        flipped: widget.flipped,
                      ),
                      size: Size(boardSize, boardSize),
                    ),
                  // Only this layer repaints as the pointer moves during a drag;
                  // the board painter and static pieces above stay put.
                  ValueListenableBuilder<Offset?>(
                    valueListenable: _currentDragPosition,
                    builder: (context, dragPos, _) {
                      if (!_isDragging ||
                          _draggedPiece == null ||
                          dragPos == null) {
                        return const SizedBox.shrink();
                      }
                      return _buildDraggedPiece(squareSize, dragPos);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Square under [localPosition], or null when the point falls outside the
  /// board (a right-drag can be released past the edge).
  String? _squareAt(Offset localPosition, double squareSize) {
    final col = (localPosition.dx / squareSize).floor();
    final row = (localPosition.dy / squareSize).floor();
    if (col < 0 || col > 7 || row < 0 || row > 7) return null;
    return _coordsToSquare(col, row);
  }

  List<Widget> _buildPieceWidgets(double squareSize) {
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
            AnimatedPositioned(
              key: ValueKey(
                'piece-${_pieceIds[squareName] ??= _nextPieceId++}',
              ),
              duration: _moveAnimationDuration,
              curve: Curves.easeOutCubic,
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
      }
    }

    return pieces;
  }

  /// Reassign every piece a fresh id — the next build renders in place with
  /// no slide. Used for the first build, flips (every coordinate changes),
  /// and position jumps bigger than one move (a new puzzle, a reset).
  void _assignAllPieceIds() {
    _pieceIds.clear();
    for (final file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (var rank = 1; rank <= 8; rank++) {
        final name = '$file$rank';
        final sq = parseSquare(name);
        if (sq != null && widget.position.board.pieceAt(sq) != null) {
          _pieceIds[name] = _nextPieceId++;
        }
      }
    }
  }

  /// Diff [oldBoard] against the new position and carry piece ids across the
  /// change, so the moved piece keeps its widget and slides. Only single-move
  /// diffs animate: each appeared piece is paired with the vacated square
  /// holding the same piece (captures never pair with their victim — the
  /// colour differs; promotions never pair — the role differs, so they pop in
  /// place, which is fine).
  void _retrackPieces(Board oldBoard) {
    final newBoard = widget.position.board;
    final vacated = <String, Piece>{};
    final appeared = <String>[];
    for (final file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (var rank = 1; rank <= 8; rank++) {
        final name = '$file$rank';
        final sq = parseSquare(name);
        if (sq == null) continue;
        final oldPiece = oldBoard.pieceAt(sq);
        final newPiece = newBoard.pieceAt(sq);
        if (oldPiece == newPiece) continue;
        if (oldPiece != null) vacated[name] = oldPiece;
        if (newPiece != null) appeared.add(name);
      }
    }
    if (vacated.isEmpty && appeared.isEmpty) return;
    // More than one move's worth of change (castling is the biggest at 2+2).
    if (vacated.length > 2 || appeared.length > 2) {
      _instantMove = null;
      _assignAllPieceIds();
      return;
    }
    final ids = <String, int>{};
    _pieceIds.forEach((square, id) {
      if (!vacated.containsKey(square)) ids[square] = id;
    });
    final instant = _instantMove;
    _instantMove = null;
    for (final dest in appeared) {
      final destSq = parseSquare(dest);
      final destPiece = destSq == null ? null : newBoard.pieceAt(destSq);
      String? source;
      if (destPiece != null) {
        for (final entry in vacated.entries) {
          if (entry.key != dest &&
              entry.value.role == destPiece.role &&
              entry.value.color == destPiece.color) {
            source = entry.key;
            break;
          }
        }
      }
      final viaDrag =
          instant != null && source == instant.$1 && dest == instant.$2;
      final carriedId = source == null ? null : _pieceIds[source];
      ids[dest] = (viaDrag || carriedId == null) ? _nextPieceId++ : carriedId;
    }
    _pieceIds
      ..clear()
      ..addAll(ids);
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

    // Always remember which square the press started on so a press that turns
    // out not to be a drag (very common on desktop, where the pan recognizer
    // wins the gesture arena after ~1px of mouse movement) can be handled as a
    // plain square tap in [_onPanEnd] instead of being discarded.
    _dragStartSquare = square;
    _dragStartPosition = details.localPosition;

    // Only lift a piece for dragging when the press lands on a movable piece.
    // Selection/highlight is applied when the drag actually begins so a press
    // without movement leaves existing selection untouched.
    final sq = parseSquare(square);
    if (sq == null) return;
    final piece = widget.position.board.pieceAt(sq);
    if (piece != null && piece.color == widget.position.turn) {
      final hasLegalMoves = widget.position.legalMoves[sq]?.isNotEmpty ?? false;
      if (hasLegalMoves) {
        _draggedPiece = piece;
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragStartSquare != null && _dragStartPosition != null) {
      final distance = (details.localPosition - _dragStartPosition!).distance;

      // A drag only "lifts" a piece; an empty/opponent square press that moves
      // is not a drag and will fall through to tap handling on release.
      if (!_isDragging && _draggedPiece != null && distance > 3) {
        setState(() {
          _isDragging = true;
          selectedSquare = _dragStartSquare;
          _highlightLegalMoves(_dragStartSquare!);
        });
        widget.onPieceSelected?.call(_dragStartSquare!);
      }

      if (_isDragging) {
        _currentDragPosition.value = details.localPosition;
      }
    }
  }

  void _onPanEnd(DragEndDetails details, double squareSize) {
    final dragPos = _currentDragPosition.value;
    if (_isDragging &&
        _draggedPiece != null &&
        _dragStartSquare != null &&
        dragPos != null) {
      final col = (dragPos.dx / squareSize).floor();
      final row = (dragPos.dy / squareSize).floor();

      if (col >= 0 && col < 8 && row >= 0 && row < 8) {
        final endSquare = _coordsToSquare(col, row);
        if (endSquare != _dragStartSquare) {
          _tryMakeMove(_dragStartSquare!, endSquare, viaDrag: true);
        }
      }
      _resetDragState();
      return;
    }

    // Not an actual drag: treat the press as a click on its square. Clear only
    // the drag bookkeeping (not the current selection) so click-to-move and
    // click-to-deselect in [_onSquareTap] still see the prior selection.
    final square = _dragStartSquare;
    _clearDragBookkeeping();
    if (square != null) {
      _onSquareTap(square);
    }
  }

  void _clearDragBookkeeping() {
    _dragStartSquare = null;
    _isDragging = false;
    _dragStartPosition = null;
    _currentDragPosition.value = null;
    _draggedPiece = null;
  }

  void _resetDragState() {
    setState(() {
      _clearDragBookkeeping();
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

  /// Map a dartchess king target (king→rook for castling) to the square the
  /// king visually lands on. See [castlingKingDestination] for why this must
  /// not be derived from raw square distance.
  Square _castlingKingDest(Square from, Square to) =>
      castlingKingDestination(widget.position, from, to);

  /// Reverse map: if user clicks the king destination, return the rook square
  /// that dartchess expects for castling.
  Square? _reverseCastlingTarget(Square from, Square clickedTo) {
    final piece = widget.position.board.pieceAt(from);
    if (piece?.role != Role.king) return null;

    final targets = widget.position.legalMoves[from];
    if (targets == null) return null;

    for (final legalTo in targets.squares) {
      if (_castlingKingDest(from, legalTo) == clickedTo &&
          legalTo != clickedTo) {
        return legalTo;
      }
    }
    return null;
  }

  Widget _buildDraggedPiece(double squareSize, Offset dragPos) {
    if (_draggedPiece == null) return const SizedBox.shrink();

    return Positioned(
      left: dragPos.dx - squareSize / 2,
      top: dragPos.dy - squareSize / 2,
      child: IgnorePointer(
        child: PieceImage(piece: _draggedPiece!, size: squareSize),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ChessBoardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.flipped != oldWidget.flipped) {
      // Every coordinate changes on a flip; sliding all 32 pieces across the
      // board would be noise, so they re-render in place.
      _assignAllPieceIds();
    } else if (widget.position.fen != oldWidget.position.fen) {
      _retrackPieces(oldWidget.position.board);
    }

    if (widget.position != oldWidget.position ||
        widget.flipped != oldWidget.flipped) {
      _resetDragState();
    }
  }

  @override
  void dispose() {
    _currentDragPosition.dispose();
    super.dispose();
  }

  void _tryMakeMove(String from, String to, {bool viaDrag = false}) {
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
      final isPromotion =
          piece?.role == Role.pawn &&
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

      // The host applies the move and the new position arrives on the next
      // build; remember a dragged move so _retrackPieces renders that piece
      // in place instead of sliding it in from its origin.
      if (viaDrag) _instantMove = (from, to);

      _clearSelection();

      widget.onMove?.call(
        CompletedMove(
          from: from,
          to: to,
          san: san,
          fenBefore: fenBefore,
          fenAfter: fenAfter,
          uci: uci,
        ),
      );
    } catch (e) {
      debugPrint('[ChessBoardWidget] Move failed: $e');
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

/// Custom painter for board squares and highlights only
class _BoardPainter extends CustomPainter {
  final String? selectedSquare;
  final Set<String> highlightedSquares;
  final Set<String> recentMoveSquares;
  final bool flipped;
  final Color lightColor;
  final Color darkColor;
  final Color selectColor;
  final Color highlightColor;
  final Color recentMoveColor;

  _BoardPainter({
    required this.selectedSquare,
    required this.highlightedSquares,
    required this.recentMoveSquares,
    required this.flipped,
    required this.lightColor,
    required this.darkColor,
    required this.selectColor,
    required this.highlightColor,
    required this.recentMoveColor,
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
          color = selectColor;
        } else {
          color = isLightSquare ? lightColor : darkColor;
        }

        final rect = Rect.fromLTWH(x, y, squareSize, squareSize);
        canvas.drawRect(rect, Paint()..color = color);

        if (recentMoveSquares.contains(square) && square != selectedSquare) {
          canvas.drawRect(rect, Paint()..color = recentMoveColor);
        }

        if (highlightedSquares.contains(square) && square != selectedSquare) {
          canvas.drawRect(
            rect,
            Paint()
              ..color = highlightColor
              ..blendMode = BlendMode.multiply,
          );
        }
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

  static (int, int) _squareToCoords(String square, bool flipped) {
    final file = square.codeUnitAt(0) - 97;
    final rank = int.parse(square[1]) - 1;

    final col = flipped ? (7 - file) : file;
    final row = flipped ? rank : (7 - rank);

    return (col, row);
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) =>
      selectedSquare != old.selectedSquare ||
      flipped != old.flipped ||
      !_setEquals(highlightedSquares, old.highlightedSquares) ||
      !_setEquals(recentMoveSquares, old.recentMoveSquares) ||
      lightColor != old.lightColor ||
      darkColor != old.darkColor ||
      selectColor != old.selectColor ||
      highlightColor != old.highlightColor ||
      recentMoveColor != old.recentMoveColor;

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
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
      ..lineTo(
        shaftEnd.dx + perp.dx * headHalfW,
        shaftEnd.dy + perp.dy * headHalfW,
      )
      ..lineTo(
        shaftEnd.dx - perp.dx * headHalfW,
        shaftEnd.dy - perp.dy * headHalfW,
      )
      ..close();

    canvas.drawPath(
      headPath,
      Paint()
        ..color = a.brush.color
        ..style = PaintingStyle.fill,
    );
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
        ..strokeWidth = math.max(strokeW, 2.0),
    );
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
        ..style = PaintingStyle.fill,
    );

    // Text
    final tp = TextPainter(
      text: TextSpan(
        text: a.label,
        style: TextStyle(
          // Light ink clears 3:1 on every brush except the amber one
          // (1.7:1 there); the yellow badge takes dark ink (9.2:1).
          color: a.brush == AnnotationBrush.yellow
              ? AppColors.onWarning
              : AppColors.ink,
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
