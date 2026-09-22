import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pv_text.dart';
import 'puzzle.dart';

/// Turning the engine's opinion of the user's moves into puzzles: which move
/// lost enough to be a mistake, and the puzzle that asks for the better one.
/// The old app's review, number for number, so a game mined by either app
/// gives the same puzzles.

/// What the engine said about one position, from the side to move: a score
/// in centipawns, or the mate distance UCI gives (`mate -3` is being mated
/// in three), and its best line as UCI moves.
final class Verdict {
  const Verdict({this.cp = 0, this.mate, this.pv = const []});

  final int cp;
  final int? mate;
  final List<String> pv;

  /// The score as centipawns, a mate in N as ±(10000 − N).
  int get packed => switch (mate) {
    null => cp,
    final m when m > 0 => 10000 - m,
    final m => -(10000 - m.abs()),
  };
}

/// Lichess's winning chance for [cp], from −1 to 1: `2 / (1 + e^(−0.00368208
/// cp)) − 1` with the score held within ±1000 first, so a swing between two
/// won positions (+8 to +15, +9 to a mate) is small rather than a blunder.
double winningChance(int cp) =>
    2 / (1 + math.exp(-0.00368208 * cp.clamp(-1000, 1000))) - 1;

/// How bad a move that took the mover's winning chance down by [drop] was,
/// or null when it lost too little to count: 0.1 is an inaccuracy, 0.2 a
/// mistake, 0.3 a blunder.
MistakeKind? mistakeFor(double drop) => drop >= 0.3
    ? MistakeKind.blunder
    : drop >= 0.2
    ? MistakeKind.mistake
    : drop >= 0.1
    ? MistakeKind.inaccuracy
    : null;

/// How bad the move between [before] (the mover to play) and [after] (the
/// opponent to play) was.
MistakeKind? judge(Verdict before, Verdict after) =>
    mistakeFor(winningChance(before.packed) - winningChance(-after.packed));

/// A score as the note writes it, from the side [before]'s mover: `+0.6`,
/// `-2.1`, `#3`, `#-4`. The note is a stored format both apps read back, so
/// this is not the display text and must not follow it.
String evalText(Verdict verdict, {bool negate = false}) {
  final mate = verdict.mate;
  if (mate != null) return '#${negate ? -mate : mate}';
  final pawns = (negate ? -verdict.cp : verdict.cp) / 100;
  return '${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(1)}';
}

/// One move the user played: the position they faced, what they played and
/// where it left the board.
final class PlayedMove {
  const PlayedMove({
    required this.before,
    required this.san,
    required this.after,
  });

  final Fen before;
  final String san;
  final Fen after;
}

/// The user's moves along [tree]'s main line, when they played [side].
List<PlayedMove> movesBy(GameTree tree, Side side) {
  final moves = <PlayedMove>[];
  var before = tree.rootFen;
  for (var nodes = tree.children; nodes.isNotEmpty; nodes = nodes[0].children) {
    final node = nodes[0];
    if (before.whiteToMove == (side == Side.white)) {
      moves.add(PlayedMove(before: before, san: node.san, after: node.fen));
    }
    before = node.fen;
  }
  return moves;
}

/// Whether the game is over at [fen]: a move that ends it has nothing to
/// punish.
bool isOver(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value)).isGameOver;
  } on Object {
    return true;
  }
}

/// Whether [move] is the engine's own first choice. Positions are compared
/// rather than move strings, because the engine and the board spell castling
/// differently.
bool playedBest(PlayedMove move, Verdict before) =>
    before.pv.isNotEmpty &&
    pvMoves(move.before, before.pv.take(1).toList()).firstOrNull?.after ==
        move.after;

/// What a puzzle needs to know about the game it came from.
final class SourceGame {
  const SourceGame({
    required this.id,
    this.white = '',
    this.black = '',
    this.date = '',
    this.moves = '',
  });

  /// [tree]'s game as its headers name it, with [id] as its game id.
  factory SourceGame.of(List<PgnHeader> tags, GameTree tree, String id) {
    final fromStart = tree.rootFen == Fen.initial;
    return SourceGame(
      id: id,
      white: tagValue(tags, 'White') ?? '',
      black: tagValue(tags, 'Black') ?? '',
      date: tagValue(tags, 'Date') ?? '',
      moves: fromStart ? numberedSan(tree.rootFen, _mainline(tree)) : '',
    );
  }

  final String id;
  final String white;
  final String black;
  final String date;

  /// The whole game as numbered moves on one line, for a game from the
  /// usual start; empty for one from a set-up position, where numbering
  /// from move one would be wrong.
  final String moves;
}

List<String> _mainline(GameTree tree) => [
  for (var nodes = tree.children; nodes.isNotEmpty; nodes = nodes[0].children)
    nodes[0].san,
];

/// A puzzle mined from one of the user's mistakes, before it is written.
final class MinedPuzzle {
  const MinedPuzzle({
    required this.fen,
    required this.played,
    required this.kind,
    required this.answer,
    required this.engineLine,
    required this.note,
    required this.refutation,
    required this.game,
  });

  /// The position the user went wrong in, with the user to play.
  final Fen fen;
  final String played;
  final MistakeKind kind;

  /// The line the solver plays, as SAN, the solver's move first.
  final List<String> answer;

  /// The engine's whole best line as SAN, shown with the solution.
  final List<String> engineLine;

  /// `h5 +0.6 → -0.1, a6 +0.6`.
  final String note;

  /// The opponent's best reply to the move played, or empty.
  final String refutation;
  final SourceGame game;
}

/// The puzzle [move] makes when it was a mistake, or null when it was not
/// one or the engine gave no line to learn.
MinedPuzzle? minedFrom(
  PlayedMove move,
  Verdict before,
  Verdict after,
  SourceGame game,
) {
  final kind = judge(before, after);
  if (kind == null) return null;
  final line = [for (final m in pvMoves(move.before, before.pv)) m.san];
  if (line.isEmpty) return null;
  final reply = pvMoves(move.after, after.pv.take(1).toList()).firstOrNull;
  final was = evalText(before);
  return MinedPuzzle(
    fen: move.before,
    played: move.san,
    kind: kind,
    answer: trainableLine(line),
    engineLine: line,
    note:
        '${move.san} $was → ${evalText(after, negate: true)}, ${line[0]} $was',
    refutation: reply?.san ?? '',
    game: game,
  );
}

/// The part of the engine's line [pv] worth asking for: its first move, and
/// then as long as every move of the solver's is forcing — a capture, a
/// check or a mate — the reply and the next forcing move, up to five moves
/// to find. A quiet move ends the puzzle, since the engine's choice among
/// quiet moves is not something to drill.
List<String> trainableLine(List<String> pv) {
  if (pv.isEmpty) return const [];
  final line = [pv[0]];
  for (var i = 0; line.length < 9 && i + 2 < pv.length; i += 2) {
    if (!_forcing(pv[i]) || !_forcing(pv[i + 2])) break;
    line
      ..add(pv[i + 1])
      ..add(pv[i + 2]);
  }
  return line;
}

bool _forcing(String san) =>
    san.contains('x') || san.contains('+') || san.contains('#');

/// [moves] numbered from [start] the way a book prints them: `8... a6 9. a4
/// Rb8`.
String numberedSan(Fen start, List<String> moves) {
  var number = start.fullMove;
  var white = start.whiteToMove;
  final words = <String>[];
  for (final (i, san) in moves.indexed) {
    if (white) {
      words.add('$number. $san');
    } else {
      words.add(i == 0 ? '$number... $san' : san);
      number++;
    }
    white = !white;
  }
  return words.join(' ');
}
