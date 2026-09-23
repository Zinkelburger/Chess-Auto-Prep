import 'package:dartchess/dartchess.dart' show Role, Side, Square;

import '../fen.dart';
import '../pgn/chapter.dart';
import '../pgn/chapter_heading.dart';
import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pgn/line_id_pins.dart';
import '../pgn/tree_edit.dart';
import 'draft_lines.dart';

/// The text of a draft chapter: the heading with `// Draft` in it, then one
/// game per kept line, in the old app's shape, so the file opens in either
/// app and its lines can be dragged into the chapter it was made for.
///
/// [rootFen] and [rootMoves] are the source chapter's own root, so every
/// game here starts where that chapter's games do; [prefix] is the way from
/// there to the position the search started at.
String draftChapterText({
  required String name,
  required Side side,
  required Fen rootFen,
  required List<String> rootMoves,
  required List<MoveNode> prefix,
  required DraftPlan plan,
  required DateTime created,
}) {
  final buffer = StringBuffer()
    ..write('// $name\n')
    ..write('// Draft\n')
    ..write('// Color: ${side == Side.white ? 'White' : 'Black'}\n')
    ..write(rootLine(rootMoves))
    ..write('// Created on ${created.toString().split('.').first}\n\n');
  final taken = <String>{};
  final white = side == Side.white;
  for (final (index, entry) in plan.entries.indexed) {
    final tree = draftTree(entry, rootFen: rootFen, prefix: prefix);
    final sans = mainlineSans(tree);
    final id = newLineId(sans, index, taken);
    taken.add(id);
    final tags = [
      PgnTag('Event', name),
      PgnTag('White', white ? 'Me' : 'Training'),
      PgnTag('Black', white ? 'Training' : 'Me'),
      const PgnTag('Result', '*'),
      if (rootFen != Fen.initial) ...[
        PgnTag('FEN', rootFen.value),
        const PgnTag('SetUp', '1'),
      ],
      PgnTag('LineID', id),
      PgnTag('CumProb', entry.line.reach.toStringAsFixed(4)),
      const PgnTag('Annotator', 'Chess Auto Prep'),
    ];
    buffer
      ..write(writeGameText(tags, tree, terminator: '*', separator: '\n'))
      ..write('\n\n');
  }
  return buffer.toString();
}

/// Every decision [chapter] already makes for its side, as
/// [DraftMove.decision] spells one, in both spellings of a castling move.
Set<String> chapterDecisions(Chapter chapter) {
  final decisions = <String>{};
  final ours = chapter.side == Side.white;
  void visit(Fen fen, List<MoveNode> children) {
    for (final child in children) {
      if (fen.whiteToMove == ours) {
        decisions.add('${fen.position}|${child.uci}');
        final standard = standardCastling(child.uci, fen);
        if (standard != null) decisions.add('${fen.position}|$standard');
      }
      visit(child.fen, child.children);
    }
  }

  visit(chapter.tree.rootFen, chapter.tree.children);
  return decisions;
}

/// The model's spelling of a castling move the tree spells king-to-rook,
/// or null for any other move. `e1h1` with a white king on e1 is `e1g1`.
String? standardCastling(String uci, Fen fen) {
  const pairs = {
    'e1h1': 'e1g1',
    'e1a1': 'e1c1',
    'e8h8': 'e8g8',
    'e8a8': 'e8c8',
  };
  final standard = pairs[uci];
  if (standard == null) return null;
  final position = positionOf(fen);
  final from = Square.parse(uci.substring(0, 2));
  if (position == null || from == null) return null;
  return position.board.pieceAt(from)?.role == Role.king ? standard : null;
}
