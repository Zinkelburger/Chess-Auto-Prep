import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_reader.dart';

/// The one way a game already in a file becomes new text.
///
/// Writing a game from a model can only keep what the model holds, so the
/// question is never "did the writer try" but "does the text still say the
/// same game". This answers it the only way that cannot be wrong: it writes
/// the game, reads the text back and compares. A game that comes back
/// different is not written at all — the file keeps its bytes and the caller
/// is told why.
sealed class LineRewrite {
  const LineRewrite();
}

/// [line] carrying the new tree, its text written again.
final class LineRewritten extends LineRewrite {
  const LineRewritten(this.line);

  final ChapterLine line;
}

/// The game must keep the bytes it has. [reason] is one plain English
/// sentence fragment for the user.
final class LineRefused extends LineRewrite {
  const LineRefused(this.reason);

  final String reason;
}

/// [line] carrying [tree], or why it cannot.
///
/// Both gates are here. A game reading did not take whole is refused before
/// anything is written, because its text holds moves the tree does not. A
/// game that passes that is written, read back and compared, which catches
/// what the model can hold but the format cannot — a `}` typed into a
/// comment is the one way a user can cause it.
LineRewrite rewritten(ChapterLine line, GameTree tree) {
  if (!line.isWhole) {
    return const LineRefused('the game was not read whole');
  }
  final text = writeGameText(
    line.tags,
    tree,
    terminator: line.terminator,
    separator: line.separator,
  );
  final back = readGame(text);
  final reason = _difference(back, line, tree);
  if (reason != null) return LineRefused(reason);
  return LineRewritten(
    ChapterLine(
      tags: line.tags,
      tree: tree,
      text: text,
      trailer: line.trailer,
      terminator: line.terminator,
      separator: line.separator,
    ),
  );
}

String? _difference(GameRead back, ChapterLine line, GameTree tree) {
  final issue = back.issues.firstOrNull;
  if (issue != null) return issue.detail;
  if (back.terminator != line.terminator) {
    return 'the game would end differently';
  }
  if (back.separator != line.separator) {
    return 'the space before the moves would change';
  }
  final headers = _headerDifference(line.tags, back.tags);
  if (headers != null) return headers;
  final read = back.tree;
  if (read == null) return 'the starting position would be lost';
  return _treeDifference(tree, read);
}

String? _headerDifference(List<PgnHeader> before, List<PgnHeader> after) {
  if (before.length != after.length) return 'a header line would be lost';
  for (var i = 0; i < before.length; i++) {
    if (before[i].text == after[i].text &&
        before[i].trailer == after[i].trailer) {
      continue;
    }
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
