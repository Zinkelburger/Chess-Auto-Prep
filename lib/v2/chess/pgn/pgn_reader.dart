import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import 'game_tree.dart';
import 'tree_edit.dart';

/// One game out of a PGN file. Headers are read for the root position and
/// then dropped; the document store step keeps them when it needs them.
final class ParsedGame {
  const ParsedGame({required this.tree});

  final GameTree tree;
}

/// Something in the text that could not become a move. The game keeps what
/// parsed before it; the branch ends there.
final class PgnIssue {
  const PgnIssue({required this.game, required this.detail});

  /// Zero-based index of the game in the file.
  final int game;
  final String detail;

  @override
  String toString() => 'game $game: $detail';
}

final class PgnReadResult {
  const PgnReadResult({required this.games, required this.issues});

  final List<ParsedGame> games;
  final List<PgnIssue> issues;
}

/// Reads PGN text into [GameTree]s.
///
/// dartchess tokenises the text and checks move legality; this file turns its
/// mutable node tree into immutable [MoveNode]s with the position after each
/// move, so nothing downstream replays moves again. A game whose `[FEN]` is
/// unusable is skipped with an issue. Comments before a move
/// (`{...} 1. e4`) are not kept yet; the document store step decides how
/// they round-trip.
PgnReadResult readPgn(String text) {
  final issues = <PgnIssue>[];
  final games = <ParsedGame>[];
  final parsed = PgnGame.parseMultiGamePgn(
    text,
    initHeaders: PgnGame.emptyHeaders,
  );
  for (final (index, game) in parsed.indexed) {
    // dartchess yields one empty game for empty text; that is not a game.
    if (game.headers.isEmpty && game.moves.children.isEmpty) continue;
    final root = _rootPosition(game.headers['FEN']);
    if (root == null) {
      issues.add(PgnIssue(game: index, detail: 'unusable FEN header'));
      continue;
    }
    final tree = GameTree(
      rootFen: Fen(root.fen),
      rootComment: game.comments.isEmpty ? null : game.comments.join(' '),
      children: _convert(game.moves.children, root, index, issues),
    );
    games.add(ParsedGame(tree: tree));
  }
  return PgnReadResult(games: games, issues: issues);
}

Position? _rootPosition(String? fen) =>
    fen == null ? Chess.initial : positionOf(Fen(fen));

List<MoveNode> _convert(
  List<PgnChildNode<PgnNodeData>> nodes,
  Position position,
  int game,
  List<PgnIssue> issues,
) {
  final out = <MoveNode>[];
  for (final node in nodes) {
    final move = position.parseSan(node.data.san);
    if (move == null) {
      issues.add(PgnIssue(game: game, detail: '${node.data.san} is not legal'));
      continue;
    }
    final (next, san) = position.makeSan(move);
    final comments = node.data.comments;
    out.add(
      MoveNode(
        san: san,
        uci: move.uci,
        fen: Fen(next.fen),
        comment: comments == null || comments.isEmpty
            ? null
            : comments.join(' '),
        nags: node.data.nags ?? const [],
        children: _convert(node.children, next, game, issues),
      ),
    );
  }
  return List.unmodifiable(out);
}
