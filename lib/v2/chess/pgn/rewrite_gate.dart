import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_reader.dart';

/// The one way a game already in a file is written again.
///
/// Writing a game from a model can only keep what the model holds, so the
/// question is never "did the writer try" but "does the text still say the
/// same game". This answers it the only way that cannot be wrong: it writes
/// the game, reads the text back and compares. A game that comes back
/// different is not written at all — the file keeps its bytes and the caller
/// is told why.
sealed class Rewrite {
  const Rewrite();
}

/// The game's text, which reads back as the game it was written from.
final class RewriteReady extends Rewrite {
  const RewriteReady(this.text);

  final String text;
}

/// The game must keep the bytes it has. [reason] is one plain English
/// sentence fragment for the user.
final class RewriteRefused extends Rewrite {
  const RewriteRefused(this.reason);

  final String reason;
}

/// [tags], [separator] and [tree] as one game's text, but only when reading
/// that text back gives the same game.
Rewrite safeGameText({
  required List<PgnHeader> tags,
  required GameTree tree,
  required String? terminator,
  required String separator,
}) {
  final text = writeGameText(
    tags,
    tree,
    terminator: terminator,
    separator: separator,
  );
  final back = readGame(text);
  final reason = _difference(back, tags, tree, terminator);
  return reason == null ? RewriteReady(text) : RewriteRefused(reason);
}

String? _difference(
  GameRead back,
  List<PgnHeader> tags,
  GameTree tree,
  String? terminator,
) {
  final issue = back.issues.firstOrNull;
  if (issue != null) return issue.detail;
  if (back.terminator != terminator) return 'the game would end differently';
  final headers = _headerDifference(tags, back.tags);
  if (headers != null) return headers;
  final read = back.tree;
  if (read == null) return 'the starting position would be lost';
  return _treeDifference(tree, read);
}

String? _headerDifference(List<PgnHeader> before, List<PgnHeader> after) {
  if (before.length != after.length) return 'a header line would be lost';
  for (var i = 0; i < before.length; i++) {
    if (before[i].text == after[i].text) continue;
    return 'the header ${before[i].text} would not come back';
  }
  return null;
}

/// Iterative, so comparing a two-thousand-ply game costs no stack.
String? _treeDifference(GameTree before, GameTree after) {
  if (before.rootFen != after.rootFen) {
    return 'the starting position would change';
  }
  if (before.rootComment != after.rootComment) {
    return 'the introduction would not come back';
  }
  final pending = [(before.children, after.children)];
  while (pending.isNotEmpty) {
    final (left, right) = pending.removeLast();
    if (left.length != right.length) return 'a move would be lost';
    final difference = _siblingsDifference(left, right, pending);
    if (difference != null) return difference;
  }
  return null;
}

String? _siblingsDifference(
  List<MoveNode> left,
  List<MoveNode> right,
  List<(List<MoveNode>, List<MoveNode>)> pending,
) {
  for (var i = 0; i < left.length; i++) {
    final difference = _nodeDifference(left[i], right[i]);
    if (difference != null) return difference;
    pending.add((left[i].children, right[i].children));
  }
  return null;
}

String? _nodeDifference(MoveNode before, MoveNode after) {
  final move = before.spelling ?? before.san;
  if (before.san != after.san || before.uci != after.uci) {
    return '$move would come back as ${after.spelling ?? after.san}';
  }
  if (before.fen != after.fen) return '$move would reach another position';
  if ((before.spelling ?? before.san) != (after.spelling ?? after.san)) {
    return '$move would be spelled differently';
  }
  if (before.comment != after.comment) {
    return 'the comment on $move would not come back';
  }
  if (before.startingComment != after.startingComment) {
    return 'the note before $move would not come back';
  }
  if (!_sameNags(before.nags, after.nags)) {
    return 'an annotation on $move would be lost';
  }
  return null;
}

bool _sameNags(List<int> before, List<int> after) {
  if (before.length != after.length) return false;
  for (var i = 0; i < before.length; i++) {
    if (before[i] != after[i]) return false;
  }
  return true;
}
