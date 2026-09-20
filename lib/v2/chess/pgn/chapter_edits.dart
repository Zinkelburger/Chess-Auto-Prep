import 'package:collection/collection.dart';
import 'package:dartchess/dartchess.dart' show Move, Side;

import '../fen.dart';
import 'chapter.dart';
import 'comment_text.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'line_id.dart';
import 'move_label.dart';
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
  const MoveAdded({required this.chapter, required this.path});

  final Chapter chapter;
  final NodePath path;
}

/// [uci] is not a legal move in the position the path asked for. The
/// chapter is untouched.
final class MoveIllegal extends AddMoveResult {
  const MoveIllegal(this.uci);

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
  final siblings = chapter.tree.nodeAt(at)?.children ?? chapter.tree.children;
  final existing = siblings.indexWhere((child) => child.san == node.san);
  if (existing >= 0) {
    return MoveAdded(chapter: chapter, path: at.child(existing));
  }
  final prefix = [for (final step in chapter.tree.lineTo(at)) step.san];
  final updated =
      (siblings.isEmpty ? _extended(chapter, prefix, node) : null) ??
      _appended(chapter, prefix, node);
  // Merging keeps the order of the moves a chapter already had and puts the
  // ones only the edited game plays after them, so a move no sibling matched
  // is the last child of the node it was played from. There is nowhere else
  // in the merged tree for it to be.
  final path = at.child(siblings.length);
  assert(
    pathOfSans(updated.tree, [...prefix, node.san]) == path,
    'a move written into a chapter came back somewhere other than $path',
  );
  return MoveAdded(chapter: updated, path: path);
}

/// Writes [text] as the comment of the node at [at].
///
/// The root path is the chapter's introduction, the comment before the
/// first move. Any other node is shared by every game that plays through
/// it, so the comment is written into all of them: reading the file back
/// keeps the first, and the old app, which reads one game at a time, shows
/// the same words whichever line the user opens. Empty text removes the
/// prose and keeps the move's `[%…]` tokens.
///
/// Text that would leave the file as it is gives the same chapter back, so a
/// caller can tell an edit from a re-statement by identity.
Chapter setComment(
  Chapter chapter, {
  required NodePath at,
  required String? text,
}) {
  if (at.isRoot) return _withIntroduction(chapter, text);
  final sans = [for (final node in chapter.tree.lineTo(at)) node.san];
  if (sans.isEmpty) return chapter;
  final lines = [
    for (final line in chapter.lines) _commented(chapter, line, sans, text),
  ];
  final changed = lines.indexed.any(
    (entry) => !identical(entry.$2, chapter.lines[entry.$1]),
  );
  return changed ? withLines(chapter, lines) : chapter;
}

ChapterLine _commented(
  Chapter chapter,
  ChapterLine line,
  List<String> sans,
  String? text,
) {
  final tree = chapter.mergedTree(line);
  if (tree == null) return line;
  final path = pathOfSans(tree, sans);
  final node = path == null ? null : tree.nodeAt(path);
  if (path == null || node == null) return line;
  final comment = withProse(node.comment, text);
  if (comment == node.comment) return line;
  return rewritten(line, withComment(tree, path, comment));
}

/// The introduction lives on the first game of the chapter, which is where
/// the merged tree takes its root comment from.
Chapter _withIntroduction(Chapter chapter, String? text) {
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.mergedTree(line);
    if (tree == null) continue;
    final comment = withProse(tree.rootComment, text);
    if (comment == tree.rootComment) return chapter;
    final lines = [...chapter.lines];
    lines[index] = rewritten(
      line,
      withComment(tree, const NodePath.root(), comment),
    );
    return withLines(chapter, lines);
  }
  return chapter;
}

/// The chapter with [node] appended to the game whose main line ends at
/// [prefix], or null when no game ends there — the end of a variation
/// inside a game does not, so that branch becomes a game of its own.
Chapter? _extended(Chapter chapter, List<String> prefix, MoveNode node) {
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.mergedTree(line);
    if (tree == null) continue;
    if (!const ListEquality<String>().equals(mainlineSans(tree), prefix)) {
      continue;
    }
    final lines = [...chapter.lines];
    lines[index] = rewritten(
      line,
      withChildAdded(tree, NodePath.of(List.filled(prefix.length, 0)), node),
    );
    return withLines(chapter, lines);
  }
  return null;
}

/// The chapter with a new game for [prefix] plus [node] at the end of the
/// file, which is where re-reading finds it as the last variation.
Chapter _appended(Chapter chapter, List<String> prefix, MoveNode node) {
  final tree = lineTree(chapter.tree.rootFen, [...prefix, node.san]);
  final tags = _newTags(chapter, prefix, tree, node);
  final lines = [...chapter.lines];
  if (lines.isNotEmpty) lines.last = _spacedAfter(lines.last);
  lines.add(
    ChapterLine(
      tags: tags,
      tree: tree,
      text: writeGameText(tags, tree),
      trailer: '\n',
    ),
  );
  return withLines(
    chapter,
    lines,
    preamble: chapter.lines.isEmpty ? _spacedPreamble(chapter.preamble) : null,
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

ChapterLine? _lineThrough(Chapter chapter, List<String> sans) {
  for (final line in chapter.lines) {
    final tree = chapter.mergedTree(line);
    if (tree != null && pathOfSans(tree, sans) != null) return line;
  }
  return null;
}

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
      );

String _spacedPreamble(String preamble) {
  if (preamble.isEmpty || preamble.endsWith('\n\n')) return preamble;
  return preamble.endsWith('\n') ? '$preamble\n' : '$preamble\n\n';
}
