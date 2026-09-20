import 'package:dartchess/dartchess.dart' show Piece, Side;
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// One chess piece, drawn from the bundled set.
///
/// The file names are the set's own: a colour letter and the piece letter in
/// capitals, `wN.svg`, `bQ.svg`. This is the one place that knows that, so a
/// piece on the board and a piece in the promotion choice are the same
/// picture.
class PieceImage extends StatelessWidget {
  const PieceImage({super.key, required this.piece});

  final Piece piece;

  @override
  Widget build(BuildContext context) {
    final color = piece.color == Side.white ? 'w' : 'b';
    return SvgPicture.asset(
      'assets/pieces/$color${piece.role.uppercaseLetter}.svg',
      fit: BoxFit.contain,
    );
  }
}
