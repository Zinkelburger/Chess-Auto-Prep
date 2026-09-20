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

sealed class CommentResult {
  const CommentResult();
}

/// The comment is in the chapter. [chapter] is the same object when the
/// words would have left the file exactly as it was.
final class CommentWritten extends CommentResult {
  const CommentWritten(this.chapter);

  final Chapter chapter;
}

/// Nothing was changed. The screen has to say so: an edit that silently
/// does nothing reads as a lost one.
sealed class CommentRefused extends CommentResult {
  const CommentRefused();
}

/// The comment belongs to a game reading could not finish, so writing that
/// game again would delete the moves reading dropped.
final class GameNotWhole extends CommentRefused {
  const GameNotWhole();
}

/// The words themselves cannot go into a PGN file. [reason] is one plain
/// English fragment saying which of them.
final class CommentUnwritable extends CommentRefused {
  const CommentUnwritable(this.reason);

  final String reason;
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
///
/// A game that was not read whole cannot take the comment: writing it again
/// would delete the moves reading dropped. One such game among those playing
/// the move refuses the whole edit rather than letting the comment land in
/// some games and not others. Words a PGN file cannot hold are refused
/// before any game is touched.
CommentResult setComment(
  Chapter chapter, {
  required NodePath at,
  required String? text,
}) {
  final unwritable = text == null ? null : commentRefusal(text);
  if (unwritable != null) return CommentUnwritable(unwritable);
  if (at.isRoot) return _withIntroduction(chapter, text);
  final sans = [for (final node in chapter.tree.lineTo(at)) node.san];
  if (sans.isEmpty) return CommentWritten(chapter);
  if (_playedByAPartialGame(chapter, sans)) return const GameNotWhole();
  final lines = [
    for (final line in chapter.lines) _commented(chapter, line, sans, text),
  ];
  final changed = lines.indexed.any(
    (entry) => !identical(entry.$2, chapter.lines[entry.$1]),
  );
  return CommentWritten(changed ? withLines(chapter, lines) : chapter);
}

/// Whether a game reading could not finish plays [sans].
bool _playedByAPartialGame(Chapter chapter, List<String> sans) {
  for (final line in chapter.lines) {
    if (line.isWhole) continue;
    final tree = chapter.treeInChapter(line);
    if (tree != null && pathOfSans(tree, sans) != null) return true;
  }
  return false;
}

ChapterLine _commented(
  Chapter chapter,
  ChapterLine line,
  List<String> sans,
  String? text,
) {
  final tree = chapter.writableTree(line);
  if (tree == null) return line;
  final path = pathOfSans(tree, sans);
  final node = path == null ? null : tree.nodeAt(path);
  if (path == null || node == null) return line;
  final comment = withProse(node.comment, text);
  if (comment == node.comment) return line;
  return rewritten(line, withComment(tree, path, comment));
}

/// The introduction lives on the first game of the chapter, which is where
/// the merged tree takes its root comment from; it has to go into that game
/// or nothing shows it.
CommentResult _withIntroduction(Chapter chapter, String? text) {
  final first = chapter.lines.firstWhereOrNull(
    (line) => chapter.treeInChapter(line) != null,
  );
  if (first == null) return CommentWritten(chapter);
  final tree = chapter.writableTree(first);
  if (tree == null) return const GameNotWhole();
  final comment = withProse(tree.rootComment, text);
  if (comment == tree.rootComment) return CommentWritten(chapter);
  final lines = [...chapter.lines];
  lines[chapter.lines.indexOf(first)] = rewritten(
    first,
    withComment(tree, const NodePath.root(), comment),
  );
  return CommentWritten(withLines(chapter, lines));
}

/// A game an edit may write again, its moves, and where it sits in
/// [Chapter.lines].
typedef _Writable = ({int index, ChapterLine line, GameTree tree});

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
Chapter? _extended(Chapter chapter, List<String> prefix, MoveNode node) {
  final found = _writableGames(chapter).firstWhereOrNull(
    (game) =>
        const ListEquality<String>().equals(mainlineSans(game.tree), prefix),
  );
  if (found == null) return null;
  final lines = [...chapter.lines];
  lines[found.index] = rewritten(
    found.line,
    withChildAdded(
      found.tree,
      NodePath.of(List.filled(prefix.length, 0)),
      node,
    ),
  );
  return withLines(chapter, lines);
}

/// The chapter with a new game for [prefix] plus [node] at the end of the
/// file, which is where re-reading finds it as the last variation.
///
/// Written straight rather than through the rewrite gate: a new game
/// replaces no bytes, so there is nothing here for a bad write to lose. That
/// it reads back as itself is what the assertion in [addMove] checks.
Chapter _appended(Chapter chapter, List<String> prefix, MoveNode node) {
  final tree = lineTree(chapter.tree.rootFen, [...prefix, node.san]);
  final tags = _newTags(chapter, prefix, tree, node);
  final lines = [...chapter.lines];
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
