import 'package:dartchess/dartchess.dart';

import 'table.dart';
import 'table_line.dart';

/// [board]'s line in [line] up to its cursor as a crazyhouse PGN, from the
/// line's start: `[Variant "Crazyhouse"]`, `[SetUp "1"]` and `[FEN …]` with
/// the hands when that board does not start as usual, then numbered SAN,
/// drops as `N@f3` and `P@e5`, and each hand edit a comment where it was
/// made, `{ +P −2b }`, White's pieces in upper case. Stops early at a move
/// the line no longer replays to.
///
/// Lichess plays it by crazyhouse rules: a piece taken stays in the taker's
/// hand there and a hand edit is only a comment, so its import stops at a
/// drop of a piece that came from the partner board or a hand edit.
String crazyhouseLinePgn(TableLine line, BoardNumber board) {
  final start = line.root.board(board);
  final words = <String>[];
  for (final node in line.pathTo(line.at(board))) {
    final entry = line.entry(node);
    if (entry is HandEdit) {
      words.add('{ ${handChangeText(entry.changes)} }');
      continue;
    }
    final move = entry as LineMove;
    if (line.goTo(board, node).replay() is! LineReplayed) break;
    if (move.side == Side.white) {
      words.add('${move.number}.');
    } else if (words.isEmpty || words.last.startsWith('{')) {
      words.add('${move.number}...');
    }
    words.add(move.san);
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
