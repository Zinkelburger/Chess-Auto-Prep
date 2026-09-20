import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import 'game_tree.dart';
import 'tree_edit.dart';

/// Something in a game's text that could not become a move. The game keeps
/// what parsed before it; the branch ends there.
final class PgnIssue {
  const PgnIssue({required this.game, required this.detail});

  /// Zero-based index of the game in the file.
  final int game;
  final String detail;

  @override
  String toString() => 'game $game: $detail';
}

/// One game read from its text.
final class GameRead {
  const GameRead({required this.tree, required this.issues});

  /// The game's moves, or null when its `[FEN]` header is not a position a
  /// game can be played from. A game nobody can read is not modelled at all,
  /// so nothing can merge it, edit it or write it back over what it holds.
  final GameTree? tree;

  /// What the text held that could not be read, in the order it held it.
  final List<String> issues;
}

/// Reads one game's PGN text into a [GameTree].
///
/// The whole of [text] is that one game, and a file is cut into games by
/// `splitChapterText`, which knows where a `{}` comment is. dartchess's own
/// multi-game split cuts on a newline followed by whitespace and `[`, which
/// a comment holding a blank line before a `[%eval …]` token matches too;
/// every move after such a cut would be dropped, and dropped moves are moves
/// the next save deletes from the file.
///
/// The text is tokenised and each move checked for legality here, so nothing
/// downstream replays them: a node carries the position after its own move.
GameRead readGame(String text) {
  final game = PgnGame.parsePgn(text, initHeaders: PgnGame.emptyHeaders);
  final root = _rootPosition(game.headers['FEN']);
  if (root == null) {
    return const GameRead(tree: null, issues: ['unusable FEN header']);
  }
  final issues = <String>[];
  return GameRead(
    tree: GameTree(
      rootFen: Fen(root.fen),
      rootComment: game.comments.isEmpty ? null : game.comments.join(' '),
      children: _convert(game.moves.children, root, issues),
    ),
    issues: List.unmodifiable(issues),
  );
}

Position? _rootPosition(String? fen) =>
    fen == null ? Chess.initial : positionOf(Fen(fen));

List<MoveNode> _convert(
  List<PgnChildNode<PgnNodeData>> nodes,
  Position position,
  List<String> issues,
) {
  final out = <MoveNode>[];
  for (final node in nodes) {
    final move = position.parseSan(node.data.san);
    if (move == null) {
      issues.add('${node.data.san} is not legal');
      continue;
    }
    final (next, san) = position.makeSan(move);
    out.add(
      MoveNode(
        san: san,
        uci: move.uci,
        fen: Fen(next.fen),
        comment: _joined(node.data.comments),
        nags: node.data.nags ?? const [],
        children: _convert(node.children, next, issues),
      ),
    );
  }
  return List.unmodifiable(out);
}

String? _joined(List<String>? comments) =>
    comments == null || comments.isEmpty ? null : comments.join(' ');
