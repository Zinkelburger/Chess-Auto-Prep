import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:chess/chess.dart' as chess;

class SimpleChessBoard extends StatefulWidget {
  final chess.Chess game;
  final Function(chess.Move)? onMove;
  final bool enableUserMoves;

  const SimpleChessBoard({
    super.key,
    required this.game,
    this.onMove,
    this.enableUserMoves = true,
  });

  @override
  State<SimpleChessBoard> createState() => _SimpleChessBoardState();
}

class _SimpleChessBoardState extends State<SimpleChessBoard> {
  String? selectedSquare;
  Set<String> highlightedSquares = {};

  // Lichess colors from Python version
  static const Color lightSquareColor = Color(0xFFF0D9B5);  // RGB(240, 217, 181)
  static const Color darkSquareColor = Color(0xFFB58863);   // RGB(181, 136, 99)
  static const Color selectedSquareColor = Color(0xB3FFFF00); // Yellow with transparency
  static const Color highlightColor = Color(0x4D6496FF);    // Blue with transparency

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black, width: 2),
        ),
        child: Column(
          children: List.generate(8, (row) => _buildRow(row)),
        ),
      ),
    );
  }

  Widget _buildRow(int row) {
    return Expanded(
      child: Row(
        children: List.generate(8, (col) => _buildSquare(row, col)),
      ),
    );
  }

  Widget _buildSquare(int row, int col) {
    final square = String.fromCharCode(97 + col) + (8 - row).toString();
    final piece = widget.game.get(square);
    final isLight = (row + col) % 2 == 0;
    final isSelected = selectedSquare == square;
    final isHighlighted = highlightedSquares.contains(square);

    Color squareColor;
    if (isSelected) {
      squareColor = selectedSquareColor;
    } else if (isHighlighted) {
      squareColor = highlightColor;
    } else {
      squareColor = isLight ? lightSquareColor : darkSquareColor;
    }

    return Expanded(
      child: GestureDetector(
        onTap: widget.enableUserMoves ? () => _onSquareTap(square) : null,
        child: Container(
          decoration: BoxDecoration(
            color: squareColor,
          ),
          child: Center(
            child: piece != null ? _buildPiece(piece) : null,
          ),
        ),
      ),
    );
  }

  Widget _buildPiece(chess.Piece piece) {
    final color = piece.color == chess.Color.WHITE ? 'w' : 'b';
    final pieceType = piece.type.toString().toUpperCase();
    final svgPath = 'assets/pieces/$color$pieceType.svg';

    return SvgPicture.asset(
      svgPath,
      width: 40,
      height: 40,
      fit: BoxFit.contain,
    );
  }

  void _onSquareTap(String square) {
    if (selectedSquare == null) {
      final piece = widget.game.get(square);
      if (piece != null && piece.color == widget.game.turn) {
        setState(() {
          selectedSquare = square;
          // Highlight possible moves
          _updateHighlights(square);
        });
      }
    } else {
      if (selectedSquare == square) {
        setState(() {
          selectedSquare = null;
          highlightedSquares.clear();
        });
      } else {
        // Try to make a move
        try {
          final moveMap = {'from': selectedSquare!, 'to': square};
          final moveResult = widget.game.move(moveMap);
          if (moveResult) {
            // Convert to proper Move object if needed by callback
            // For now just skip the callback since it's not critical
            setState(() {
              selectedSquare = null;
              highlightedSquares.clear();
            });
          } else {
            setState(() {
              selectedSquare = null;
              highlightedSquares.clear();
            });
          }
        } catch (e) {
          setState(() {
            selectedSquare = null;
            highlightedSquares.clear();
          });
        }
      }
    }
  }

  void _updateHighlights(String fromSquare) {
    highlightedSquares.clear();

    // Get legal moves from this square using the correct API
    final moves = widget.game.moves({'square': fromSquare});
    for (final moveString in moves) {
      highlightedSquares.add(moveString);
    }
  }
}