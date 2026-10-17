import 'package:dartchess/dartchess.dart';

import 'table.dart';
import 'table_line.dart';

/// One move of a board, with the board as it stood before it.
typedef BoardStep = ({Crazyhouse before, String san});

/// [board]'s first [count] moves of [line] as a crazyhouse PGN that Lichess
/// imports: see [crazyhousePgn]. Stops early at a move the line no longer
/// replays to.
String crazyhouseLinePgn(TableLine line, BoardNumber board, int count) {
  final moves = line.of(board).take(count).toList();
  final steps = <BoardStep>[];
  for (final (i, move) in moves.indexed) {
    final replay = line.go(board, i).replay();
    if (replay is! LineReplayed) break;
    steps.add((before: replay.position.board(board), san: move.san));
  }
  final start = switch (line.go(board, 0).replay()) {
    LineReplayed(:final position) => position.board(board),
    LineBroken() => line.root.board(board),
  };
  return crazyhousePgn(start, steps);
}

/// [steps] from [start] as a crazyhouse PGN: `[Variant "Crazyhouse"]`,
/// `[SetUp "1"]` and `[FEN …]` with the hands when the start is not the
/// usual one, then numbered SAN, drops as `N@f3` and `P@e5`.
///
/// The PGN is played by crazyhouse rules, so a piece taken goes to the
/// taker's own hand rather than the partner's. A move those rules do not
/// allow there — a drop of a piece that came from the partner board or a
/// hand edit — starts the PGN again from the board just before it, so
/// every move written plays.
String crazyhousePgn(Crazyhouse start, List<BoardStep> steps) {
  var from = start;
  Position game = start;
  final sans = <String>[];
  for (final step in steps) {
    var move = game.parseSan(step.san);
    if (move == null) {
      from = step.before;
      game = step.before;
      sans.clear();
      move = game.parseSan(step.san);
      if (move == null) break;
    }
    final (next, san) = game.makeSan(move);
    sans.add(san.startsWith('@') ? 'P$san' : san);
    game = next;
  }
  final tags = [
    '[Variant "Crazyhouse"]',
    if (from.fen != Crazyhouse.initial.fen) ...[
      '[SetUp "1"]',
      '[FEN "${from.fen}"]',
    ],
  ];
  return '${tags.join('\n')}\n\n${_movetext(from, sans)}';
}

/// [sans] numbered from [from], `12... Nc6 13. d4`, then `*`.
String _movetext(Crazyhouse from, List<String> sans) {
  final words = <String>[];
  var number = from.fullmoves;
  var white = from.turn == Side.white;
  for (final (i, san) in sans.indexed) {
    if (white) {
      words.add('$number.');
    } else if (i == 0) {
      words.add('$number...');
    }
    words.add(san);
    if (!white) number++;
    white = !white;
  }
  words.add('*');
  return words.join(' ');
}
