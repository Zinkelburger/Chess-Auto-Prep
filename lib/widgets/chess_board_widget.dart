import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:chess/chess.dart' as chess;

/// A professional chess board widget that properly scales and handles interaction.
/// Uses a simple, maintainable approach: CustomPainter for board + SVG widgets for pieces
class ChessBoardWidget extends StatefulWidget {
  final chess.Chess game;
  final Function(chess.Move)? onMove;
  final bool enableUserMoves;
  final bool flipped;
  final Set<String> highlightedSquares;
  final Function(String)? onSquareClicked;
  final Function(String)? onPieceSelected;

  const ChessBoardWidget({
    super.key,
    required this.game,
    this.onMove,
    this.enableUserMoves = true,
    this.flipped = false,
    this.highlightedSquares = const {},
    this.onSquareClicked,
    this.onPieceSelected,
  });

  @override
  State<ChessBoardWidget> createState() => _ChessBoardWidgetState();
}

class _ChessBoardWidgetState extends State<ChessBoardWidget> {
  String? selectedSquare;
  final Set<String> _internalHighlights = {};

  // Drag and drop state
  String? _dragStartSquare;
  bool _isDragging = false;
  Offset? _dragStartPosition;
  Offset? _currentDragPosition;
  chess.Piece? _draggedPiece;

  // Colors matching the Python implementation
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

        return Container(
          width: boardSize,
          height: boardSize,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black, width: 2),
          ),
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
              // Only handle tap if we're not dragging
              if (!_isDragging) {
                final col = (details.localPosition.dx / squareSize).floor();
                final row = (details.localPosition.dy / squareSize).floor();
                final square = _coordsToSquare(col, row);
                _onSquareTap(square);
              }
            },
            child: Stack(
              children: [
                // Board squares and highlights
                CustomPaint(
                  painter: _BoardPainter(
                    selectedSquare: selectedSquare,
                    highlightedSquares: {...widget.highlightedSquares, ..._internalHighlights},
                    flipped: widget.flipped,
                  ),
                  size: Size(boardSize, boardSize),
                ),

                // SVG Pieces as positioned widgets
                ..._buildPieceWidgets(boardSize, squareSize),

                // Draw dragged piece at cursor position
                if (_isDragging && _draggedPiece != null && _currentDragPosition != null)
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

    // Trust the chess library - iterate through all 64 squares correctly
    for (String file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (int rank = 1; rank <= 8; rank++) {
        final square = '$file$rank';
        final piece = widget.game.get(square);

        if (piece != null) {
          // Skip drawing if this piece is being dragged
          if (_isDragging && square == _dragStartSquare) {
            continue;
          }

          // Convert square name to screen coordinates
          final (col, row) = _squareToCoords(square);
          final x = col * squareSize;
          final y = row * squareSize;

          pieces.add(
            Positioned(
              left: x,
              top: y,
              width: squareSize,
              height: squareSize,
              child: IgnorePointer( // FIX: Let taps pass through to parent GestureDetector
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

  /// Convert square name (e.g., "e4") to screen coordinates (col, row)
  (int, int) _squareToCoords(String square) {
    return _BoardPainter._squareToCoords(square, widget.flipped);
  }

  /// Convert screen coordinates to square name (e.g., (4,4) -> "e4")
  String _coordsToSquare(int col, int row) {
    // Reverse the orientation transformation
    final file = widget.flipped ? (7 - col) : col;
    final rank = widget.flipped ? row : (7 - row);

    return String.fromCharCode(97 + file) + (rank + 1).toString();
  }

  void _onPanStart(DragStartDetails details, double squareSize) {
    final col = (details.localPosition.dx / squareSize).floor();
    final row = (details.localPosition.dy / squareSize).floor();
    final square = _coordsToSquare(col, row);

    final piece = widget.game.get(square);
    if (piece != null && piece.color == widget.game.turn) {
      // Check if there are legal moves from this square
      final allMoves = widget.game.generate_moves();
      final hasLegalMoves = allMoves.any((move) => move.fromAlgebraic == square);

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

      // Start dragging if moved far enough (3 pixels threshold like Python)
      if (!_isDragging && distance > 3) {
        setState(() {
          _isDragging = true;
        });
      }

      // Update drag position
      if (_isDragging) {
        setState(() {
          _currentDragPosition = details.localPosition;
        });
      }
    }
  }

  void _onPanEnd(DragEndDetails details, double squareSize) {
    if (_isDragging && _dragStartSquare != null && _currentDragPosition != null) {
      // Calculate end square from final position
      final col = (_currentDragPosition!.dx / squareSize).floor();
      final row = (_currentDragPosition!.dy / squareSize).floor();

      if (col >= 0 && col < 8 && row >= 0 && row < 8) {
        final endSquare = _coordsToSquare(col, row);
        if (endSquare != _dragStartSquare) {
          _tryMakeMove(_dragStartSquare!, endSquare);
        }
      }
    }

    // Reset drag state
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
      final piece = widget.game.get(square);
      if (piece != null && piece.color == widget.game.turn) {
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

    // Get all legal moves for the current position
    final allMoves = widget.game.generate_moves();

    // Filter moves that start from the selected square and add their target squares
    for (final move in allMoves) {
      if (move.fromAlgebraic == fromSquare) {
        _internalHighlights.add(move.toAlgebraic);
      }
    }
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

    // If the game object changes (e.g., parent updated it) or the board flips,
    // we must reset the local selection state.
    if (widget.game != oldWidget.game || widget.flipped != oldWidget.flipped) {
      _resetDragState();
    }
  }

  void _tryMakeMove(String from, String to) {
    try {
      // The move function returns true on success, false on failure
      final moveResult = widget.game.move({'from': from, 'to': to});

      if (moveResult) {
        setState(() {
          selectedSquare = null;
          _internalHighlights.clear();
        });

        // Create a mock Move object and call the callback
        final move = _MockMove(fromSquare: from, toSquare: to);
        widget.onMove?.call(move);
      } else {
        // Failed move (illegal)
        setState(() {
          selectedSquare = null;
          _internalHighlights.clear();
        });
      }
    } catch (e) {
      // Exception (e.g., bad format)
      setState(() {
        selectedSquare = null;
        _internalHighlights.clear();
      });
    }
  }
}

/// Mock Move class to satisfy the callback interface
class _MockMove implements chess.Move {
  final String fromSquare;
  final String toSquare;

  _MockMove({required this.fromSquare, required this.toSquare});

  @override
  String get fromAlgebraic => fromSquare;

  @override
  String get toAlgebraic => toSquare;

  @override
  int get from => _squareToIndex(fromSquare);

  @override
  int get to => _squareToIndex(toSquare);

  @override
  chess.PieceType? get captured => null;

  @override
  chess.Color get color => chess.Color.WHITE;

  @override
  int get flags => 0;

  @override
  chess.PieceType? get promotion => null;

  String get san => '$fromSquare$toSquare';

  int _squareToIndex(String square) {
    final file = square.codeUnitAt(0) - 97; // 'a' = 0
    final rank = int.parse(square[1]) - 1; // '1' = 0
    return rank * 8 + file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Simple piece widget that renders SVG pieces
class _PieceWidget extends StatelessWidget {
  final chess.Piece piece;
  final double size;

  const _PieceWidget({
    required this.piece,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final color = piece.color == chess.Color.WHITE ? 'w' : 'b';
    // Convert piece type to uppercase character
    final type = piece.type.toString().toUpperCase();
    final assetPath = 'assets/pieces/$color$type.svg';

    return Center( // FIX: Center the piece within its square
      child: SvgPicture.asset(
        assetPath,
        width: size * 0.85, // Slightly smaller than square for better appearance
        height: size * 0.85,
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

    // Draw board squares and highlights using proper square mapping
    for (String file in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      for (int rank = 1; rank <= 8; rank++) {
        final square = '$file$rank';

        // Convert to screen coordinates
        final (col, row) = _squareToCoords(square, flipped);
        final x = col * squareSize;
        final y = row * squareSize;

        // Determine square color based on chess square
        final fileIndex = file.codeUnitAt(0) - 97;
        final rankIndex = rank - 1; // FIX: Use 0-based index
        final isLightSquare = (fileIndex + rankIndex) % 2 != 0; // FIX: Check for non-zero

        Color color;
        if (square == selectedSquare) {
          color = _ChessBoardWidgetState.selectedSquareColor;
        } else if (highlightedSquares.contains(square)) {
          color = isLightSquare
              ? _ChessBoardWidgetState.lightSquareColor
              : _ChessBoardWidgetState.darkSquareColor;
        } else {
          color = isLightSquare
              ? _ChessBoardWidgetState.lightSquareColor
              : _ChessBoardWidgetState.darkSquareColor;
        }

        // Draw square
        final rect = Rect.fromLTWH(x, y, squareSize, squareSize);
        canvas.drawRect(rect, Paint()..color = color);

        // Draw highlight overlay if needed
        if (highlightedSquares.contains(square) && square != selectedSquare) {
          canvas.drawRect(rect, Paint()
            ..color = _ChessBoardWidgetState.highlightColor
            ..blendMode = BlendMode.multiply);
        }
      }
    }
  }

  /// Convert square name to screen coordinates (shared logic)
  static (int, int) _squareToCoords(String square, bool flipped) {
    final file = square.codeUnitAt(0) - 97; // 'a' = 0, 'b' = 1, etc.
    final rank = int.parse(square[1]) - 1;   // '1' = 0, '2' = 1, etc.

    // Apply board orientation
    final col = flipped ? (7 - file) : file;
    final row = flipped ? rank : (7 - rank);

    return (col, row);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}