import 'package:collection/collection.dart';

import 'chapter.dart';
import 'chapter_line.dart';
import 'comment_text.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'rewrite_gate.dart';
import 'tree_edit.dart';

/// Commenting a chapter: pure functions from one [Chapter] to the next.
///
/// A move is shared by every game that plays through it, so where the words
/// go is a decision, not a detail; [setComment] says which one.

sealed class CommentResult {
  const CommentResult();
}

/// The comment is in the chapter. [chapter] is the same object when the
/// words would have left the file exactly as it was.
final class CommentWritten extends CommentResult {
  const CommentWritten(this.chapter, {required this.written});

  final Chapter chapter;

  /// The games this edit wrote; a move several games play is written into
  /// all of them.
  final GamesWritten written;
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
  return _edited(chapter, at, (comment) => withProse(comment, text));
}

/// Puts the bare token [marker] on the move at [at], or takes it away.
///
/// A marker is not prose: it says something about the move to whoever reads
/// the file next — a quiz starts here, a quiz ends here — and the words the
/// user typed are left exactly as they are. The root has no move to mark.
CommentResult setMarker(
  Chapter chapter, {
  required NodePath at,
  required String marker,
  required bool on,
}) {
  if (at.isRoot) return _unchanged(chapter);
  return _edited(
    chapter,
    at,
    (comment) => withToken(comment, marker, present: on),
  );
}

/// The comment on the move at [at], put through [change], in every game the
/// note belongs in.
CommentResult _edited(
  Chapter chapter,
  NodePath at,
  String? Function(String? comment) change,
) {
  final sans = [for (final node in chapter.tree.lineTo(at)) node.san];
  if (sans.isEmpty) return _unchanged(chapter);
  if (_playedByAPartialGame(chapter, sans)) return const GameNotWhole();
  final lines = [...chapter.lines];
  final written = <int>{};
  for (final index in _commentHomes(chapter, sans)) {
    switch (_commented(chapter, chapter.lines[index], sans, change)) {
      case LineRefused(:final reason):
        // Nothing is committed until every game the edit must write can be
        // written, so a note never lands in some games and not others.
        return CommentUnwritable(reason);
      case LineRewritten(:final line):
        lines[index] = line;
        written.add(index);
      case null:
        break;
    }
  }
  if (written.isEmpty) return _unchanged(chapter);
  return CommentWritten(
    withLines(chapter, lines),
    written: GamesWritten(rewritten: written),
  );
}

/// The games a comment on [sans] belongs in: every game that already holds
/// one on that move, or, when none does, the first game that plays it.
///
/// A move is shared by every game through it, and writing the note into all
/// of them rewrote 844 of the 930 games of one real course for one note.
/// The comment lives where it lived; reading a chapter still merges the
/// comments of all its games, so the workspace shows the same words.
List<int> _commentHomes(Chapter chapter, List<String> sans) {
  final holders = <int>[];
  int? first;
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.writableTree(line);
    if (tree == null) continue;
    final path = pathOfSans(tree, sans);
    if (path == null) continue;
    first ??= index;
    if (tree.nodeAt(path)?.comment != null) holders.add(index);
  }
  if (holders.isNotEmpty) return holders;
  return [?first];
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

/// [line] with the comment on [sans] put through [change], the reason it
/// cannot be, or null when there is nothing there to change.
LineRewrite? _commented(
  Chapter chapter,
  ChapterLine line,
  List<String> sans,
  String? Function(String? comment) change,
) {
  final tree = chapter.writableTree(line);
  if (tree == null) return null;
  final path = pathOfSans(tree, sans);
  final node = path == null ? null : tree.nodeAt(path);
  if (path == null || node == null) return null;
  final comment = change(node.comment);
  if (comment == node.comment) return null;
  return rewritten(line, withComment(tree, path, comment));
}

/// The introduction lives on the first game of the chapter, which is where
/// the merged tree takes its root comment from; it has to go into that game
/// or nothing shows it.
CommentResult _withIntroduction(Chapter chapter, String? text) {
  final first = chapter.lines.firstWhereOrNull(
    (line) => chapter.treeInChapter(line) != null,
  );
  if (first == null) return _unchanged(chapter);
  final tree = chapter.writableTree(first);
  if (tree == null) return const GameNotWhole();
  final comment = withProse(tree.rootComment, text);
  if (comment == tree.rootComment) return _unchanged(chapter);
  final written = rewritten(
    first,
    withComment(tree, const NodePath.root(), comment),
  );
  if (written case LineRefused(:final reason)) {
    return CommentUnwritable(reason);
  }
  final index = chapter.lines.indexOf(first);
  final lines = [...chapter.lines];
  lines[index] = (written as LineRewritten).line;
  return CommentWritten(
    withLines(chapter, lines),
    written: GamesWritten(rewritten: {index}),
  );
}

/// The chapter as it was, because the words would have left the file
/// exactly as it is.
CommentResult _unchanged(Chapter chapter) =>
    CommentWritten(chapter, written: GamesWritten.nothing);
