import 'package:dartchess/dartchess.dart' show Role, Side;

import 'table.dart';
import 'table_line.dart';
import 'table_setup.dart';

/// [line]'s moves as BPGN movetext in the order played, `1A. e4 1B. d4
/// 1a. e5`: the number is the board's own move number and the letter's case
/// is the mover's colour. The order is what makes it replayable, since a
/// drop on one board needs the capture on the other that came before it. A
/// hand edit is a comment where it was made, `{ Hands edited on board 1:
/// +N −2p }`, White's pieces in upper case. Lines are wrapped at 80
/// columns, as PGN writes them.
String bpgnMovetext(TableLine line) {
  final tokens = <String>[];
  (BoardNumber, int)? noted;
  for (final entry in line.entries) {
    switch (entry) {
      case LineMove(:final board, :final side, :final number, :final san):
        noted = null;
        tokens.add('$number${_letter(board, side)}. $san');
      case HandEdit(:final board, :final after):
        // One comment for each place edited, with the net change there.
        if (noted == (board, after)) continue;
        noted = (board, after);
        final text = handChangeText(line.handChanges(board, after));
        if (text.isNotEmpty) {
          tokens.add('{ $_editNote ${board.digit}: $text }');
        }
    }
  }
  final lines = <String>[];
  var current = '';
  for (final token in tokens) {
    if (current.isNotEmpty && current.length + token.length + 1 > 80) {
      lines.add(current);
      current = '';
    }
    current = current.isEmpty ? token : '$current $token';
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.join('\n');
}

const _editNote = 'Hands edited on board';

String _letter(BoardNumber board, Side side) {
  final letter = board == BoardNumber.one ? 'A' : 'B';
  return side == Side.white ? letter : letter.toLowerCase();
}

/// What the Bughouse mode copies: the line's movetext, after a
/// `SetUpDualFEN` tag when it does not start from the usual table.
String tableLineText(TableLine line) {
  final moves = bpgnMovetext(line);
  return line.root.dualFen == TablePosition.initial.dualFen
      ? moves
      : '[SetUpDualFEN "${line.root.lichessDualFen}"]\n\n$moves';
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

final _token = RegExp(
  r'\{\s*'
  '$_editNote'
  r'\s*([12])\s*:([^}]*)\}'
  r'|\{[^}]*\}'
  r'|(\d+)([AaBb])\.\s*([^\s{}()]+)',
);
final _change = RegExp('([+−-])(\\d*)([pnbrqPNBRQ])');

/// BPGN movetext back into a line: what [tableLineText] writes, hand edits
/// included, or a FICS game. Tags other than `SetUpDualFEN`, other comments
/// and results are passed over; every move must play, in order, or nothing
/// is taken.
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
  final body = text.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  var line = TableLine(root);
  var position = root;
  var taken = false;
  for (final token in _token.allMatches(body)) {
    if (token[1] case final digit?) {
      final board = digit == '1' ? BoardNumber.one : BoardNumber.two;
      for (final change in _change.allMatches(token[2]!)) {
        final letter = change[3]!;
        final count = int.tryParse(change[2]!) ?? 1;
        line = line.edited(
          board,
          letter == letter.toUpperCase() ? Side.white : Side.black,
          Role.values.firstWhere((r) => r.letter == letter.toLowerCase()),
          change[1] == '+' ? count : -count,
        );
        taken = true;
      }
      position = (line.replay() as LineReplayed).position;
      continue;
    }
    final san = token[5];
    if (san == null) continue;
    final board = token[4]!.toUpperCase() == 'A'
        ? BoardNumber.one
        : BoardNumber.two;
    final move = position.moveBySan(board, san);
    final played = move == null ? null : lineMove(position, board, move.uci);
    if (played == null) return PastedMovesRefused(token[0]);
    line = line.played(played.move);
    position = played.after;
    taken = true;
  }
  if (!taken) return const PastedMovesRefused(null);
  return PastedLine(line);
}
