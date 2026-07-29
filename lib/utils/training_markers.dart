/// Puzzle-segment markers carried in PGN comments as `[%tstart]` / `[%tend]`
/// tokens.
///
/// A study chapter is just a line of moves; these markers are how the user
/// says "the puzzle is *this part* of the line". `[%tstart]` on a move means
/// training quizzes from that move (everything earlier auto-plays as intro,
/// and in studies the solver's colour is the side that plays the marked
/// move); `[%tend]` marks the last quizzed move. Like board shapes
/// (`board_shape_comments.dart`), the tokens live in the move's comment so
/// they survive any PGN round-trip, and [filterDisplayComment] already strips
/// them from displayed prose.
library;

import '../models/move_tree.dart';

final _startRe = RegExp(r'\[%tstart\s*\]');
final _endRe = RegExp(r'\[%tend\s*\]');

/// Whether [comment] carries the puzzle-start marker.
bool hasPuzzleStart(String? comment) =>
    comment != null && _startRe.hasMatch(comment);

/// Whether [comment] carries the puzzle-end marker.
bool hasPuzzleEnd(String? comment) =>
    comment != null && _endRe.hasMatch(comment);

/// Rewrite [comment] so it carries the marker exactly when [on].
///
/// Prose and other tokens (shapes, evals) are preserved; the token is
/// appended after the existing text, matching how shapes are written.
/// Returns null when nothing is left, which is what the tree stores for
/// "no comment".
String? writePuzzleMarker(
  String? comment, {
  required bool start,
  required bool on,
}) {
  final re = start ? _startRe : _endRe;
  final token = start ? '[%tstart]' : '[%tend]';
  final rest = (comment ?? '')
      .replaceAll(re, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (!on) return rest.isEmpty ? null : rest;
  return rest.isEmpty ? token : '$rest $token';
}

/// Toggle the start/end marker on the node at [target].
///
/// Turning a marker on clears the same marker from every other node, so a
/// chapter never has two competing starts (the trainer would silently obey
/// the first and confuse whoever marked the second). All comment rewrites go
/// through [setComment] so the host's persistence (dirty marking, autosave)
/// sees each change.
///
/// Returns true when the marker is set on [target] afterwards, false when
/// the call cleared it.
bool togglePuzzleMarker(
  MoveTree tree,
  TreePath target, {
  required bool start,
  required void Function(TreePath path, String? comment) setComment,
}) {
  final node = tree.nodeAt(target);
  if (node == null) return false;
  final has = start ? hasPuzzleStart(node.comment) : hasPuzzleEnd(node.comment);
  final on = !has;

  // Collect first, then apply: setComment mutates the tree being walked.
  final changes = <(TreePath, String?)>[];
  void walk(List<MoveNode> siblings, TreePath parent) {
    for (var i = 0; i < siblings.length; i++) {
      final path = parent.child(i);
      final n = siblings[i];
      final isTarget = path == target;
      final carries = start
          ? hasPuzzleStart(n.comment)
          : hasPuzzleEnd(n.comment);
      if (isTarget || (on && carries)) {
        final next = writePuzzleMarker(
          n.comment,
          start: start,
          on: isTarget && on,
        );
        if (next != n.comment) changes.add((path, next));
      }
      walk(n.children, path);
    }
  }

  walk(tree.roots, TreePath.empty);
  for (final (path, comment) in changes) {
    setComment(path, comment);
  }
  return on;
}
