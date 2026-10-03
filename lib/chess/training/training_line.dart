import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import '../pgn/chapter.dart';
import '../pgn/chapter_line.dart';
import '../pgn/comment_text.dart' show hasToken;
import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pgn/line_id_pins.dart';
import '../pgn/study.dart';
import '../pgn/tree_edit.dart' show nullMoveSan;
import 'schedule.dart';

/// One game of a repertoire chapter as the trainer drills it: the moves of
/// its main line from its own start, for the chapter's side.
///
/// A study's quiz markers narrow what is asked: the moves before the one
/// marked `[%tstart]` play themselves, and nothing after the one marked
/// `[%tend]` is asked or played. `1.e4 e5 2.Nf3 {[%tstart]} Nc6 3.Bb5
/// {[%tend]} a6` trained as White plays 1.e4 e5 by itself, asks for 2.Nf3
/// and 3.Bb5, and stops there: [quizStart] is 2 and [quizEnd] is 5.
final class TrainingLine {
  TrainingLine({
    required this.key,
    required this.chapter,
    required this.name,
    required this.side,
    required this.start,
    required this.moves,
    required this.game,
    required this.modelGame,
    this.likelihood,
    this.quizStart = 0,
    int? quizEnd,
  }) : quizEnd = quizEnd ?? moves.length;

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

  /// The first ply asked for: the moves before it play themselves.
  final int quizStart;

  /// How many plies the drill goes to: it ends on the board after them.
  final int quizEnd;

  /// The position before the move at [ply].
  Fen fenBefore(int ply) => ply == 0 ? start : moves[ply - 1].fen;

  /// Whether the move at [ply] is the user's to find. A ply where nobody
  /// moved, or one outside the quiz markers, is played for them whichever
  /// side it falls to.
  bool isYours(int ply) =>
      ply >= quizStart &&
      ply < quizEnd &&
      moves[ply].san != nullMoveSan &&
      _moverAt(ply) == side;

  /// How many of the line's moves are the user's to find.
  int get yourMoves => [
    for (var ply = quizStart; ply < quizEnd; ply++)
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
  final ids = chapter.lineIds ?? trainedIdsOf(chapter);
  // A study read whole keeps each chapter's own side; a repertoire file,
  // or a study given a `// Color:` line, has one side for every line.
  final ownSides =
      chapter.game != null ||
      (statedSide(chapter.preamble) == null &&
          studyNameIn(chapter.lines) != null);
  return [
    for (final (index, line) in chapter.lines.indexed)
      if (!ownSides || (studyTrainingSide(line) != null && line.isWhole))
        if (ids[index] case final id?)
          _lineOf(
            line,
            index,
            chapter: chapter.name,
            key: (source: source, id: id),
            side: ownSides ? studyTrainingSide(line)! : chapter.side,
          ),
  ];
}

TrainingLine _lineOf(
  ChapterLine line,
  int index, {
  required String chapter,
  required LineKey key,
  required Side side,
}) {
  final moves = List<MoveNode>.unmodifiable(_mainLine(line.tree!));
  final window = quizWindow(moves);
  return TrainingLine(
    key: key,
    chapter: chapter,
    name: line.nameAt(index),
    side: side,
    start: line.tree!.rootFen,
    moves: moves,
    game: index,
    modelGame: _isModelGame(line),
    likelihood: _likelihood(line),
    quizStart: window.start,
    quizEnd: window.end,
  );
}

/// The plies of [moves] a quiz asks: from the first move marked
/// `[%tstart]` up to and including the first marked `[%tend]`, the whole
/// line where a marker is missing. An end marked before the start would
/// leave nothing to ask, so it is not taken, as the old app did not take it.
({int start, int end}) quizWindow(List<MoveNode> moves) {
  int? first(String marker) {
    final at = moves.indexWhere((move) => hasToken(move.comment, marker));
    return at < 0 ? null : at;
  }

  final start = first(quizStartMarker) ?? 0;
  final end = first(quizEndMarker);
  return (
    start: start,
    end: end == null || end < start ? moves.length : end + 1,
  );
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
