import 'package:collection/collection.dart';
import 'package:dartchess/dartchess.dart' show Move, Side;

import '../fen.dart';
import 'chapter.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'line_id.dart';
import 'move_label.dart';
import 'rewrite_gate.dart';
import 'tree_edit.dart';

/// Editing a chapter: pure functions from one [Chapter] to the next.
///
/// A chapter's persistent unit is the game, and the tree the workspace shows
/// is every game merged. So an edit changes one or more games and the tree
/// is merged again from them; a game nothing touched keeps its bytes.

sealed class AddMoveResult {
  const AddMoveResult();
}

/// The move is in the chapter at [path]. [chapter] is unchanged when the
/// move was already there and the caller only has to move its cursor.
final class MoveAdded extends AddMoveResult {
  const MoveAdded({
    required this.chapter,
    required this.path,
    required this.written,
  });

  final Chapter chapter;
  final NodePath path;

  /// The games this edit wrote; none of them when the move was already
  /// there.
  final GamesWritten written;
}

/// [uci] is not a legal move in the position the path asked for. The
/// chapter is untouched.
final class MoveIllegal extends AddMoveResult {
  const MoveIllegal(this.uci);

  final String uci;
}

/// The move could be played but the chapter it came back in does not hold
/// it, so nothing was written.
///
/// Nothing should ever produce this. It is a result rather than an
/// assertion because the alternative is a release build writing a game that
/// does not hold the move the user just made, and telling them it did.
final class MoveNotWritten extends AddMoveResult {
  const MoveNotWritten(this.uci);

  final String uci;
}

/// Plays [uci] after the node at [at] and writes it into the file.
///
/// Where it lands follows the shape of the tree there. A move that is
/// already a child changes nothing. A node with no continuation yet extends
/// the game whose main line ends exactly there. A node that already has
/// continuations is a branch point, and a branch is a new game — that is
/// what a chapter file means by a line.
AddMoveResult addMove(
  Chapter chapter, {
  required NodePath at,
  required String uci,
}) {
  final move = Move.parse(uci);
  final node = move == null ? null : moveNode(chapter.tree.fenAt(at), move);
  if (node == null) return MoveIllegal(uci);
  final here = playedAlready(chapter, at: at, uci: uci);
  if (here != null) {
    return MoveAdded(
      chapter: chapter,
      path: here,
      written: GamesWritten.nothing,
    );
  }
  final siblings = chapter.tree.nodeAt(at)?.children ?? chapter.tree.children;
  final prefix = [for (final step in chapter.tree.lineTo(at)) step.san];
  final edited =
      (siblings.isEmpty ? _extended(chapter, prefix, node) : null) ??
      _appended(chapter, prefix, node);
  // Merging keeps the order of the moves a chapter already had and puts the
  // ones only the edited game plays after them, so a move no sibling matched
  // is the last child of the node it was played from. There is nowhere else
  // in the merged tree for it to be — and if it is not there, the chapter
  // the edit produced is not one anybody may save.
  final path = at.child(siblings.length);
  if (pathOfSans(edited.chapter.tree, [...prefix, node.san]) != path) {
    return MoveNotWritten(uci);
  }
  return MoveAdded(
    chapter: edited.chapter,
    path: path,
    written: edited.written,
  );
}

/// Where [chapter] already plays [uci] after the node at [at], or null when
/// it does not play it there.
///
/// Following a move the chapter already holds writes nothing, and answering
/// that costs one move rather than a whole edited chapter, so a caller that
/// only wants to know whether an edit would write can ask this first.
NodePath? playedAlready(
  Chapter chapter, {
  required NodePath at,
  required String uci,
}) {
  final move = Move.parse(uci);
  final node = move == null ? null : moveNode(chapter.tree.fenAt(at), move);
  if (node == null) return null;
  final siblings = chapter.tree.nodeAt(at)?.children ?? chapter.tree.children;
  final index = siblings.indexWhere((child) => child.san == node.san);
  return index < 0 ? null : at.child(index);
}

/// A game an edit may write again, its moves, and where it sits in
/// [Chapter.lines].
typedef _Writable = ({int index, ChapterLine line, GameTree tree});

/// A chapter an edit produced and the games it wrote to produce it.
typedef _Edited = ({Chapter chapter, GamesWritten written});

/// The games of [chapter] an edit may write again, in file order.
Iterable<_Writable> _writableGames(Chapter chapter) sync* {
  for (final (index, line) in chapter.lines.indexed) {
    if (chapter.writableTree(line) case final tree?) {
      yield (index: index, line: line, tree: tree);
    }
  }
}

/// The chapter with [node] appended to the game whose main line ends at
/// [prefix], or null when no game an edit may write ends there — the end of
/// a variation inside a game does not, and neither does a game that was not
/// read whole, so in both cases that branch becomes a game of its own and
/// nothing already in the file is written again.
_Edited? _extended(Chapter chapter, List<String> prefix, MoveNode node) {
  final found = _writableGames(chapter).firstWhereOrNull(
    (game) =>
        const ListEquality<String>().equals(mainlineSans(game.tree), prefix),
  );
  if (found == null) return null;
  final written = rewritten(
    found.line,
    withChildAdded(
      found.tree,
      NodePath.of(List.filled(prefix.length, 0)),
      node,
    ),
  );
  // A game the gate refuses is a game that keeps its bytes, so the move
  // becomes a game of its own instead; nothing already in the file moves.
  if (written is! LineRewritten) return null;
  final lines = [...chapter.lines];
  lines[found.index] = written.line;
  return (
    chapter: withLines(chapter, lines),
    written: GamesWritten(rewritten: {found.index}),
  );
}

/// The chapter with a new game for [prefix] plus [node] at the end of the
/// file, which is where re-reading finds it as the last variation.
///
/// Written straight rather than through the rewrite gate: a new game
/// replaces no bytes, so there is nothing here for a bad write to lose. That
/// it reads back as itself is what the assertion in [addMove] checks.
_Edited _appended(Chapter chapter, List<String> prefix, MoveNode node) {
  final tree = lineTree(chapter.tree.rootFen, [...prefix, node.san]);
  final tags = _newTags(chapter, prefix, tree, node);
  final lines = [...chapter.lines];
  // The game before it only gains the blank line that puts the new one on a
  // line of its own, which is not a game written again.
  if (lines.isNotEmpty) lines.last = _spacedAfter(lines.last);
  lines.add(
    ChapterLine(
      tags: tags,
      tree: tree,
      text: writeGameText(tags, tree, terminator: '*', separator: '\n'),
      trailer: '\n',
      terminator: '*',
      separator: '\n',
    ),
  );
  return (
    chapter: withLines(
      chapter,
      lines,
      preamble: chapter.lines.isEmpty
          ? _spacedPreamble(chapter.preamble)
          : null,
    ),
    written: GamesWritten(appended: 1),
  );
}

/// The tags the old app gives a new line: whose it is, that it is study
/// material rather than a finished game, the root when it is not the
/// initial position, and the id every later lookup needs.
List<PgnTag> _newTags(
  Chapter chapter,
  List<String> prefix,
  GameTree tree,
  MoveNode branch,
) {
  final white = chapter.side == Side.white;
  return List.unmodifiable([
    PgnTag('Event', _title(chapter, prefix, branch)),
    PgnTag('White', white ? 'Me' : 'Training'),
    PgnTag('Black', white ? 'Training' : 'Me'),
    const PgnTag('Result', '*'),
    if (tree.rootFen != Fen.initial) ...[
      PgnTag('FEN', tree.rootFen.value),
      const PgnTag('SetUp', '1'),
    ],
    PgnTag(
      'LineID',
      newLineId(mainlineSans(tree), chapter.lines.length, _takenIds(chapter)),
    ),
  ]);
}

/// Header values that name nobody, so a branch label on them would read as
/// a title where there is none.
const _placeholders = {
  '',
  '?',
  'me',
  'opponent',
  'training',
  'white',
  'black',
  'n.n.',
  'repertoire line',
  'edited line',
};

/// A branch is named after the game it left and the move it left on —
/// `Sicilian: Repertoire for Black — 3.Nc3` — so a chapter's line list
/// still reads as one chapter.
String _title(Chapter chapter, List<String> prefix, MoveNode branch) {
  final parent = _lineThrough(chapter, prefix);
  final title = parent == null ? '' : tagValue(parent.tags, 'Event')?.trim();
  if (title == null || _placeholders.contains(title.toLowerCase())) {
    return 'Repertoire Line';
  }
  final label = moveNumberLabel(branch, startsLine: true);
  return '$title — $label${branch.san}';
}

ChapterLine? _lineThrough(Chapter chapter, List<String> sans) =>
    chapter.lines.firstWhereOrNull((line) {
      final tree = chapter.treeInChapter(line);
      return tree != null && pathOfSans(tree, sans) != null;
    });

Set<String> _takenIds(Chapter chapter) {
  final ids = <String>{};
  for (final line in chapter.lines) {
    final id = line.lineId;
    if (id != null) ids.add(id);
  }
  return ids;
}

/// [line] with a blank line after it, so the game appended next starts its
/// own `[Event ` line.
ChapterLine _spacedAfter(ChapterLine line) => line.trailer.endsWith('\n\n')
    ? line
    : ChapterLine(
        tags: line.tags,
        tree: line.tree,
        text: line.text,
        trailer: '\n\n',
        terminator: line.terminator,
        separator: line.separator,
        issues: line.issues,
      );

String _spacedPreamble(String preamble) {
  if (preamble.isEmpty || preamble.endsWith('\n\n')) return preamble;
  return preamble.endsWith('\n') ? '$preamble\n' : '$preamble\n\n';
}
