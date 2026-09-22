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
  return _edited(
    chapter,
    at,
    (node) => _commented(node, withProse(node.comment, text)),
    holds: (node) => node.comment != null,
  );
}

/// Puts the glyph [nag] (`!`, `?`, `!!`, `??`, `!?` or `?!`, the numeric
/// annotations 1 to 6) on the move at [at], in place of any of those six it
/// had, or takes them all away when [nag] is null. Other annotation numbers
/// stay: they say things these six do not.
CommentResult setGlyph(Chapter chapter, {required NodePath at, int? nag}) {
  if (at.isRoot) return _unchanged(chapter);
  return _edited(
    chapter,
    at,
    (node) => _glyphed(node, nag),
    holds: (node) => node.nags.any(isGlyph),
  );
}

/// Whether [nag] is one of the six glyphs a reader prints after a move.
bool isGlyph(int nag) => nag >= 1 && nag <= 6;

MoveNode _glyphed(MoveNode node, int? nag) {
  final kept = [
    for (final old in node.nags)
      if (!isGlyph(old)) old,
  ];
  final nags = [?nag, ...kept];
  return _sameNags(nags, node.nags) ? node : withNags(node, nags);
}

bool _sameNags(List<int> a, List<int> b) =>
    a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

/// [node] with [comment] in place of the one it had; the same node when it
/// already has those words.
MoveNode _commented(MoveNode node, String? comment) =>
    comment == node.comment ? node : withNodeComment(node, comment);

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
    (node) => _commented(node, withToken(node.comment, marker, present: on)),
    holds: (node) => node.comment != null,
  );
}

/// The move at [at], put through [change], in every game the annotation
/// belongs in: the games that already hold one on that move ([holds]), or
/// the first game that plays it.
CommentResult _edited(
  Chapter chapter,
  NodePath at,
  MoveNode Function(MoveNode node) change, {
  required bool Function(MoveNode node) holds,
}) {
  final sans = [for (final node in chapter.tree.lineTo(at)) node.san];
  if (sans.isEmpty) return _unchanged(chapter);
  if (_playedByAPartialGame(chapter, sans)) return const GameNotWhole();
  final lines = [...chapter.lines];
  final written = <int>{};
  for (final index in _homes(chapter, sans, holds)) {
    switch (_changed(chapter, chapter.lines[index], sans, change)) {
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

/// The games an annotation on [sans] belongs in: every game that already
/// holds one on that move, or, when none does, the first game that plays it.
///
/// A move is shared by every game through it, and writing the note into all
/// of them rewrote 844 of the 930 games of one real course for one note.
/// The comment lives where it lived; reading a chapter still merges the
/// comments of all its games, so the workspace shows the same words.
List<int> _homes(
  Chapter chapter,
  List<String> sans,
  bool Function(MoveNode node) holds,
) {
  final holders = <int>[];
  int? first;
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.writableTree(line);
    if (tree == null) continue;
    final path = pathOfSans(tree, sans);
    if (path == null) continue;
    first ??= index;
    final node = tree.nodeAt(path);
    if (node != null && holds(node)) holders.add(index);
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

/// [line] with the move on [sans] put through [change], the reason it
/// cannot be, or null when there is nothing there to change.
LineRewrite? _changed(
  Chapter chapter,
  ChapterLine line,
  List<String> sans,
  MoveNode Function(MoveNode node) change,
) {
  final tree = chapter.writableTree(line);
  if (tree == null) return null;
  final path = pathOfSans(tree, sans);
  final node = path == null ? null : tree.nodeAt(path);
  if (path == null || node == null) return null;
  final changed = change(node);
  if (identical(changed, node)) return null;
  return rewritten(line, withNodeChanged(tree, path, (_) => changed));
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
