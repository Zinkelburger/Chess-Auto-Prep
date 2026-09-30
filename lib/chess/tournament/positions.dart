import '../pgn/game_text.dart';
import '../pgn/pgn_reader.dart';

/// One final main-line FEN per PGN game. A truncated/illegal game has no
/// preview: the last readable prefix must not masquerade as its final board.
List<String?> tournamentPositions(String pgn) => [
  for (final span in splitChapterText(pgn).games) _last(span.text),
];

String? _last(String text) {
  final game = readGame(text);
  final tree = game.tree;
  if (tree == null || game.issues.isNotEmpty) return null;
  var position = tree.rootFen;
  var continuation = tree.children;
  while (continuation.isNotEmpty) {
    final next = continuation.first;
    position = next.fen;
    continuation = next.children;
  }
  return position.value;
}
