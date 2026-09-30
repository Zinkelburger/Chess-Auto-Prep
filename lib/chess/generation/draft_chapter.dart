import 'package:dartchess/dartchess.dart' show Role, Side, Square;

import '../fen.dart';
import '../openings.dart';
import '../pgn/chapter.dart';
import '../pgn/chapter_edit.dart';
import '../pgn/chapter_edits.dart';
import '../pgn/chapter_heading.dart';
import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pgn/games_written.dart';
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
///
/// Each line is named after the last position of it [openings] names —
/// `Ruy Lopez: Closed` — so the lines of a draft can be told apart in a
/// list; a line the book has no name for keeps the draft's [name].
String draftChapterText({
  required String name,
  required Side side,
  required Fen rootFen,
  required List<String> rootMoves,
  required List<MoveNode> prefix,
  required DraftPlan plan,
  required DateTime created,
  required Openings openings,
}) {
  final buffer = StringBuffer(
    draftHeading(
      name: name,
      side: side,
      rootMoves: rootMoves,
      created: created,
    ),
  );
  final taken = <String>{};
  final white = side == Side.white;
  for (final (index, entry) in plan.entries.indexed) {
    final tree = draftTree(entry, rootFen: rootFen, prefix: prefix);
    final sans = mainlineSans(tree);
    final id = newLineId(sans, index, taken);
    taken.add(id);
    final opening = openings.ofMainLine(tree);
    final tags = [
      PgnTag('Event', opening?.name ?? name),
      PgnTag('White', white ? 'Me' : 'Training'),
      PgnTag('Black', white ? 'Training' : 'Me'),
      const PgnTag('Result', '*'),
      if (rootFen != Fen.initial) ...[
        PgnTag('FEN', rootFen.value),
        const PgnTag('SetUp', '1'),
      ],
      if (opening != null) PgnTag('ECO', opening.eco),
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

/// The `//` heading of a draft chapter [name] for [side], starting after
/// [rootMoves]: a chapter heading with `// Draft` in it, which is what
/// marks a draft for either app. Every draft starts with it, whatever goes
/// under it.
String draftHeading({
  required String name,
  required Side side,
  required List<String> rootMoves,
  required DateTime created,
}) =>
    '// $name\n'
    '// Draft\n'
    '// Color: ${side == Side.white ? 'White' : 'Black'}\n'
    '${rootLine(rootMoves)}'
    '// Created on ${created.toString().split('.').first}\n\n';

/// [sans], played from [chapter]'s start, added to it as one edit — one
/// undo, and the cursor stays where it is. The moves it already holds are
/// followed and the rest written as the board writes a move ([addMove]),
/// so the chapter comes out as if the line had been played into it. A
/// move that is not legal where it falls, or that cannot be written, is a
/// refusal and nothing changes.
ChapterEdit lineAdded(Chapter chapter, List<String> sans) {
  var edited = chapter;
  GamesArranged? arranged;
  var at = const NodePath.root();
  for (final san in sans) {
    final move = positionOf(edited.tree.fenAt(at))?.parseSan(san);
    if (move == null) return ChapterEditRefused('$san is not legal there');
    switch (addMove(edited, at: at, uci: move.uci)) {
      case MoveIllegal() || MoveNotWritten():
        return ChapterEditRefused('$san could not be written');
      case MoveRefused(:final reason):
        return ChapterEditRefused(reason);
      case MoveAdded(chapter: final next, :final path, :final written):
        final step = GamesArranged.of(written, before: edited.lines.length);
        arranged = arranged == null
            ? step
            : composedArrangement(arranged, step);
        if (arranged == null) {
          return ChapterEditRefused('$san could not be written');
        }
        edited = next;
        at = path;
    }
  }
  if (arranged == null || identical(edited, chapter)) {
    return const ChapterUnchanged();
  }
  return ChapterEdited(edited, arranged);
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
