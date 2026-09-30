import 'package:dartchess/dartchess.dart' show Side;

import 'table.dart';
import 'table_line.dart';
import 'table_setup.dart';

/// [moves] as BPGN movetext in the order played, `1A. e4 1B. d4 1a. e5`:
/// the number is the board's own move number and the letter's case is the
/// mover's colour. The order is what makes it replayable, since a drop on
/// one board needs the capture on the other that came before it. Lines are
/// wrapped at 80 columns, as PGN writes them.
String bpgnMovetext(List<LineMove> moves) {
  final lines = <String>[];
  var current = '';
  for (final move in moves) {
    final token =
        '${move.number}${_letter(move.board, move.side)}. ${move.san}';
    if (current.isNotEmpty && current.length + token.length + 1 > 80) {
      lines.add(current);
      current = '';
    }
    current = current.isEmpty ? token : '$current $token';
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.join('\n');
}

String _letter(BoardNumber board, Side side) {
  final letter = board == BoardNumber.one ? 'A' : 'B';
  return side == Side.white ? letter : letter.toLowerCase();
}

/// What the lab copies: the line's movetext, after a `SetUpDualFEN` tag when
/// it does not start from the usual table.
String tableLineText(TableLine line) {
  final moves = bpgnMovetext(line.moves);
  return line.root.dualFen == TablePosition.initial.dualFen
      ? moves
      : '[SetUpDualFEN "${line.root.dualFen}"]\n\n$moves';
}

sealed class PastedMoves {
  const PastedMoves();
}

final class PastedLine extends PastedMoves {
  const PastedLine(this.line);

  final TableLine line;
}

/// Nothing was pasted. [token] is the first move that does not play, or
/// null when the text holds no bughouse moves at all.
final class PastedMovesRefused extends PastedMoves {
  const PastedMovesRefused(this.token);

  final String? token;
}

final _moveToken = RegExp(r'(\d+)([AaBb])\.\s*([^\s{}()]+)');

/// BPGN movetext back into a line: what [tableLineText] writes or a FICS
/// game. Tags other than `SetUpDualFEN`, comments and results are passed
/// over; every move must play, in order, or nothing is taken.
PastedMoves readTableLineText(String text) {
  var root = TablePosition.initial;
  final setup = RegExp(r'\[SetUpDualFEN "([^"]*)"\]').firstMatch(text);
  if (setup != null) {
    switch (readDualFen(setup[1]!)) {
      case SetupReady(:final position):
        root = position;
      case SetupRefused():
        return PastedMovesRefused(setup[0]);
    }
  }
  final body = text
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\{[^}]*\}'), ' ');
  final tokens = _moveToken.allMatches(body).toList();
  if (tokens.isEmpty) return const PastedMovesRefused(null);
  var line = TableLine(root);
  var position = root;
  for (final token in tokens) {
    final board = token[2]!.toUpperCase() == 'A'
        ? BoardNumber.one
        : BoardNumber.two;
    final move = position.moveBySan(board, token[3]!);
    final played = move == null ? null : lineMove(position, board, move.uci);
    if (played == null) return PastedMovesRefused(token[0]);
    line = line.played(played.move);
    position = played.after;
  }
  return PastedLine(line);
}
