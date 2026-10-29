import 'package:dartchess/dartchess.dart';

import 'table.dart';
import 'table_line.dart';

/// [board]'s first [count] moves of [line] as a crazyhouse PGN, from the
/// line's start: `[Variant "Crazyhouse"]`, `[SetUp "1"]` and `[FEN …]` with
/// the hands when that board does not start as usual, then numbered SAN,
/// drops as `N@f3` and `P@e5`, and each hand edit a comment where it was
/// made, `{ +P −2b }`, White's pieces in upper case. Stops early at a move
/// the line no longer replays to.
///
/// Lichess plays it by crazyhouse rules: a piece taken stays in the taker's
/// hand there and a hand edit is only a comment, so its import stops at a
/// drop of a piece that came from the partner board or a hand edit.
String crazyhouseLinePgn(TableLine line, BoardNumber board, int count) {
  final start = line.root.board(board);
  final words = <String>[];
  void noteEdits(int after) {
    final text = handChangeText(line.handChanges(board, after));
    if (text.isNotEmpty) words.add('{ $text }');
  }

  noteEdits(0);
  for (final (i, move) in line.of(board).take(count).indexed) {
    if (line.go(board, i + 1).replay() is! LineReplayed) break;
    if (move.side == Side.white) {
      words.add('${move.number}.');
    } else if (words.isEmpty || words.last.startsWith('{')) {
      words.add('${move.number}...');
    }
    words.add(move.san);
    noteEdits(i + 1);
  }
  words.add('*');
  final tags = [
    '[Variant "Crazyhouse"]',
    if (start.fen != Crazyhouse.initial.fen) ...[
      '[SetUp "1"]',
      '[FEN "${lichessFen(start.fen)}"]',
    ],
  ];
  return '${tags.join('\n')}\n\n${words.join(' ')}';
}
