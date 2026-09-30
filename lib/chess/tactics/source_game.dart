import '../fen.dart';
import '../pgn/game_summary.dart';
import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pgn/pgn_reader.dart';
import '../pgn/study.dart' show ChapterDraft;
import '../pgn/tree_edit.dart' show lineTree;
import 'puzzle.dart';

/// The game a puzzle was mined from, as the Tactics Game tab shows it: its
/// headers, its main line and which move the puzzle is about.
final class PuzzleGame {
  const PuzzleGame({
    required this.text,
    required this.tags,
    required this.tree,
    required this.result,
    required this.moves,
    required this.mistake,
  });

  /// The game as PGN: the saved download when there is one, else what the
  /// puzzle's own headers say of it.
  final String text;
  final List<PgnHeader> tags;
  final GameTree tree;

  /// The termination marker the game ends with, or null when it has none.
  final String? result;

  Fen get root => tree.rootFen;

  /// The main line, one node per ply.
  final List<MoveNode> moves;

  /// The index in [moves] of the move played at the puzzle's position — the
  /// board before it is the puzzle — or null when the game never reaches it.
  final int? mistake;

  String tag(String key) => tagValue(tags, key)?.trim() ?? '';

  List<String> get sans => [for (final move in moves) move.san];
}

/// [puzzle]'s game: [saved], the downloaded game its `GameId` names, when
/// the cache has it; else the game written from the puzzle's `White`,
/// `Black`, `Date` and `SourceMovetext`. Null when there is neither, as for
/// a puzzle made by hand.
PuzzleGame? puzzleGame(Puzzle puzzle, {String? saved}) {
  final fromSet = puzzle.sourceMoves.isEmpty ? null : _fromSet(puzzle);
  for (final text in [?saved, ?fromSet]) {
    final read = readGame(text);
    final tree = read.tree;
    if (tree == null || tree.children.isEmpty) continue;
    final moves = _mainLine(tree);
    return PuzzleGame(
      text: text,
      tags: read.tags,
      tree: tree,
      result: read.terminator,
      moves: moves,
      mistake: _mistakeIn(tree.rootFen, moves, puzzle.fen),
    );
  }
  return null;
}

/// [puzzle]'s [game] as a chapter on its way into a study, seen from the
/// solver's side and named as the game on the board would be
/// ([summarizeTags]); the puzzle alone — its position and answer — when it
/// came from no game.
ChapterDraft studyDraft(Puzzle puzzle, PuzzleGame? game) => game == null
    ? ChapterDraft(
        name: puzzle.label,
        orientation: puzzle.toMove,
        moves: lineTree(puzzle.fen, puzzle.answer),
      )
    : ChapterDraft(
        name: summarizeTags(game.tags, index: 0).title,
        orientation: puzzle.toMove,
        moves: game.tree,
        tags: game.tags,
        result: game.result == '*' ? null : game.result,
      );

String _fromSet(Puzzle puzzle) {
  String header(String key, String value) => '${PgnTag(key, value).text}\n';
  return '${header('White', puzzle.white)}'
      '${header('Black', puzzle.black)}'
      '${puzzle.date.isEmpty ? '' : header('Date', puzzle.date)}'
      '${header('Result', '*')}'
      '\n${puzzle.sourceMoves} *';
}

List<MoveNode> _mainLine(GameTree tree) => [
  for (var nodes = tree.children; nodes.isNotEmpty; nodes = nodes[0].children)
    nodes[0],
];

/// The first ply whose position before it is [puzzle], by position only:
/// the move counters of a puzzle and its game can differ.
int? _mistakeIn(Fen root, List<MoveNode> moves, Fen puzzle) {
  final wanted = puzzle.position;
  for (var ply = 0; ply < moves.length; ply++) {
    final before = ply == 0 ? root : moves[ply - 1].fen;
    if (before.position == wanted) return ply;
  }
  return null;
}
