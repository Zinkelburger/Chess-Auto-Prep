import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import '../pgn/chapter.dart';
import '../pgn/chapter_line.dart';
import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pgn/line_id.dart';
import '../pgn/tree_edit.dart' show nullMoveSan;
import 'schedule.dart';

/// One game of a repertoire chapter as the trainer drills it: the moves of
/// its main line from its own start, for the chapter's side.
final class TrainingLine {
  const TrainingLine({
    required this.key,
    required this.chapter,
    required this.name,
    required this.side,
    required this.start,
    required this.moves,
    required this.game,
    required this.modelGame,
    this.likelihood,
  });

  /// The chapter file and the line's id in it, as the progress files have it.
  final LineKey key;

  /// The chapter's name, for a list that shows lines of several chapters.
  final String chapter;
  final String name;

  /// The side the user plays: the chapter's.
  final Side side;
  final Fen start;

  /// The main line, one node per ply; each carries the position after it.
  final List<MoveNode> moves;

  /// The game's place in its file.
  final int game;

  /// A whole game kept to be read — a course's model game, or any game that
  /// ended in a result — rather than a line to learn. It is listed and never
  /// drilled.
  final bool modelGame;

  /// How likely the opponent is to steer into the line, from 0 to 1, as a
  /// generated chapter writes it in `CumProb`; null when the file does not
  /// say.
  final double? likelihood;

  /// The position before the move at [ply].
  Fen fenBefore(int ply) => ply == 0 ? start : moves[ply - 1].fen;

  /// Whether the move at [ply] is the user's to find. A ply where nobody
  /// moved is played for them whichever side it falls to.
  bool isYours(int ply) =>
      moves[ply].san != nullMoveSan && _moverAt(ply) == side;

  /// How many of the line's moves are the user's.
  int get yourMoves => [
    for (var ply = 0; ply < moves.length; ply++)
      if (isYours(ply)) ply,
  ].length;

  Side _moverAt(int ply) {
    final first = start.whiteToMove ? Side.white : Side.black;
    return ply.isEven ? first : first.opposite;
  }
}

/// The lines of [chapter], in file order, keyed under [source], the chapter
/// file's path. A game with no moves, or one nothing could read, is no line
/// but keeps its place, so the ids of the games after it do not move.
List<TrainingLine> trainingLines(Chapter chapter, {required String source}) {
  final games = [
    for (final (index, line) in chapter.lines.indexed)
      if (line.tree case final tree? when tree.children.isNotEmpty)
        (index: index, line: line, moves: _mainLine(tree)),
  ];
  final ids = trainingLineIds([
    for (final game in games)
      (
        index: game.index,
        header: game.line.lineId,
        sans: [for (final m in game.moves) m.spelling ?? m.san],
      ),
  ]);
  return [
    for (final (i, game) in games.indexed)
      TrainingLine(
        key: (source: source, id: ids[i]),
        chapter: chapter.name,
        name: game.line.nameAt(game.index),
        side: chapter.side,
        start: game.line.tree!.rootFen,
        moves: List.unmodifiable(game.moves),
        game: game.index,
        modelGame: _isModelGame(game.line),
        likelihood: _likelihood(game.line),
      ),
  ];
}

List<MoveNode> _mainLine(GameTree tree) {
  final moves = <MoveNode>[];
  var children = tree.children;
  while (children.isNotEmpty) {
    moves.add(children.first);
    children = children.first.children;
  }
  return moves;
}

bool _isModelGame(ChapterLine line) {
  if (tagValue(line.tags, 'ModelGameWhite') != null ||
      tagValue(line.tags, 'ModelGameResult') != null) {
    return true;
  }
  final result = tagValue(line.tags, 'Result')?.trim() ?? '*';
  return result.isNotEmpty && result != '*';
}

/// `[CumProb "0.1253"]` as this app writes it, `[CumProb "12.53%"]` as the
/// old one did, or the older `[Importance "0.125"]`.
double? _likelihood(ChapterLine line) {
  for (final key in const ['CumProb', 'Importance']) {
    final raw = tagValue(line.tags, key)?.trim();
    if (raw == null || raw.isEmpty) continue;
    final percent = raw.endsWith('%');
    final value = double.tryParse(
      percent ? raw.substring(0, raw.length - 1) : raw,
    );
    if (value == null) continue;
    return percent || value > 1 ? value / 100 : value;
  }
  return null;
}
