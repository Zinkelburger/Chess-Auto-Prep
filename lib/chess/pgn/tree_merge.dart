import 'board_shapes.dart';
import 'comment_text.dart';
import 'game_tree.dart';

/// Merges the forest [b] into [a].
///
/// A move present in both keeps [a]'s place in the list, [a]'s comments and
/// NAGs unless [a] has none, and the merged continuations of both. Moves only
/// in [b] are appended in [b]'s order. So when a chapter's games are folded
/// in file order, the first game fixes the main line and every later game can
/// only add variations, never reorder what is already there.
///
/// Two nodes are the same move when their SAN is equal; both forests hang off
/// the same position, so equal SAN means an equal move and an equal FEN.
///
/// One forest is folded the same way, so a single game that writes the same
/// reply twice — `1. e4 e5 (1... e5 {alt}) 2. Nf3` — still gives one node per
/// move. Two siblings with one SAN would break the one thing the rest of the
/// app relies on: that a line of SAN names and a path through the tree say
/// the same thing, and that the cursor lands where the move is.
///
/// [a] is empty or a forest this function produced, so it already plays no
/// move twice and is taken as it is. Looking through it again for something
/// to fold would walk the whole tree built so far once per game added to it,
/// which is minutes on a file of ten thousand separate games.
///
/// With [joinNotes], a move present in both keeps [a]'s comments and NAGs
/// and adds [b]'s after them instead of dropping them. That is folding a
/// line into another for good, where the line folded in is deleted after
/// and a note only it carried would be in neither game. [hostMoves] tracks
/// the original host through recursion so repeats inside a new variation
/// can keep the arriving game's own annotations.
List<MoveNode> mergeForests(
  List<MoveNode> a,
  List<MoveNode> b, {
  bool joinNotes = false,
  List<MoveNode>? hostMoves,
}) {
  if (b.isEmpty) return a;
  if (a.isEmpty && !_playsAMoveTwice(b)) return b;
  final merged = [...a];
  for (final incoming in b) {
    final i = merged.indexWhere((node) => node.san == incoming.san);
    if (i < 0) {
      merged.add(_folded(incoming, joinNotes: joinNotes));
      continue;
    }
    final existing = merged[i];
    final host = joinNotes ? (hostMoves ?? a).elementAtOrNull(i) : null;
    String? join(String? first, String? next) =>
        host == null && first == null ? next : joinedComment(first, next);
    final children = mergeForests(
      existing.children,
      incoming.children,
      joinNotes: joinNotes,
      hostMoves: host?.children ?? const [],
    );
    merged[i] = joinNotes
        ? existing.copyWith(
            startingComment: join(
              existing.startingComment,
              incoming.startingComment,
            ),
            comment: join(existing.comment, incoming.comment),
            nags: [
              ...existing.nags,
              for (final nag in incoming.nags)
                if (!existing.nags.contains(nag)) nag,
            ],
            children: children,
          )
        : existing.copyWith(
            startingComment:
                existing.startingComment ?? incoming.startingComment,
            comment: existing.comment ?? incoming.comment,
            nags: existing.nags.isEmpty ? incoming.nags : existing.nags,
            children: children,
          );
  }
  return List.unmodifiable(merged);
}

/// The tokens that say what happened in one game or one drill, which a
/// move another line also plays does not take from it.
final _gameTokens = RegExp(
  r' ?\[%(?:tstart|tend|clk|emt|egt|mct)(?:\s+[^\]]*)?\] ?',
);
final _eval = RegExp(r'\[%eval\s+[^\]]*\]');

/// [host]'s comment with the prose and board shapes [arriving] adds to it,
/// and its evaluation where [host] has none. Quiz markers and clock times
/// stay as [host] wrote them, so a move with no comment of its own takes
/// [arriving]'s without them.
String? joinedComment(String? host, String? arriving) {
  if (arriving == null) return host;
  if (host == null) {
    final text = arriving.replaceAll(_gameTokens, ' ').trim();
    if (text.isEmpty) return null;
    // A review's mark with no evaluation left to own says nothing.
    return _eval.hasMatch(text)
        ? text
        : withToken(text, _reviewEval, present: false);
  }
  final prose = displayComment(arriving);
  final eval = host.contains('[%eval') || hasToken(host, _reviewEval)
      ? null
      : _eval.firstMatch(arriving);
  return withMissingShapes(
    [
      host,
      if (prose.isNotEmpty && !displayComment(host).contains(prose)) prose,
      if (eval != null) ...[
        eval[0]!,
        // Still the review's to clear, as it was in the line it came from.
        if (hasToken(arriving, _reviewEval)) '[%$_reviewEval]',
      ],
    ].join(' '),
    arriving,
  );
}

const _reviewEval = 'cap_review_eval';

/// [node] with the moves under it folded, or [node] itself when there was
/// nothing to fold, which is the whole of an ordinary game.
MoveNode _folded(MoveNode node, {required bool joinNotes}) {
  final children = mergeForests(const [], node.children, joinNotes: joinNotes);
  return identical(children, node.children)
      ? node
      : node.copyWith(children: children);
}

/// Whether [forest] or anything under it gives one move two nodes.
bool _playsAMoveTwice(List<MoveNode> forest) {
  final sans = <String>{};
  for (final node in forest) {
    if (!sans.add(node.san) || _playsAMoveTwice(node.children)) return true;
  }
  return false;
}
