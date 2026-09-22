import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';

/// Copies a game's mainline without comments, variations or annotation glyphs.
/// Headers (including custom starting positions) and the result are retained.
String mainlinePgnWithoutComments(String pgnText) {
  final game = parsePgnGame(pgnText, initHeaders: PgnGame.emptyHeaders);
  final root = PgnNode<PgnNodeData>();
  PgnNode<PgnNodeData> parent = root;
  for (final move in game.moves.mainline()) {
    final child = PgnChildNode(PgnNodeData(san: move.san));
    parent.children.add(child);
    parent = child;
  }
  return PgnGame(
    headers: game.headers,
    moves: root,
    comments: const [],
  ).makePgn().trim();
}
