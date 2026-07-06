/// Shared SVG piece rendering used by the play board and the board editor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:dartchess/dartchess.dart';

import '../../utils/chess_utils.dart' show roleChar;

/// Renders a single chess piece from the bundled SVG assets.
class PieceImage extends StatelessWidget {
  final Piece piece;
  final double size;

  const PieceImage({super.key, required this.piece, required this.size});

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
