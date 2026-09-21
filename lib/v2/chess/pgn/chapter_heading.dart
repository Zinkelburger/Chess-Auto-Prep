import '../fen.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'move_label.dart';
import 'tree_edit.dart';

/// What the `//` lines above a chapter's first game say about the chapter as
/// a whole, apart from its side: where it starts and whether it is finished.
///
/// The old app writes `// Root: 1. d4 d5 2. c4` when a chapter is made from
/// a position rather than from the start, and nothing ever showed it. Here
/// it is what the outline prints under the chapter's name, so a user can
/// set a chapter up for the King's Gambit and see that it is one. It is also
/// where an empty chapter's board starts, since with no game there is no
/// `[FEN]` tag to start it from.
///
/// `// Draft` marks a chapter that holds proposed lines — a fill's output,
/// a big import — rather than lines the user has accepted. The outline
/// shows it greyed as "Proposed", and the trainer leaves it alone.
final class ChapterHeading {
  const ChapterHeading({this.rootMoves = const [], this.draft = false});

  /// The moves from the initial position to where the chapter starts, as
  /// SAN, or empty for a chapter that starts at the start.
  final List<String> rootMoves;

  final bool draft;

  static const none = ChapterHeading();

  bool get startsAtTheStart => rootMoves.isEmpty;

  /// The root as a person reads it: `1.e4 e5 2.f4`, or empty.
  String get rootText => movesFrom(lineTree(Fen.initial, rootMoves), plies: 40);

  /// Where the chapter's games start: the position after [rootMoves].
  Fen get rootFen {
    final tree = lineTree(Fen.initial, rootMoves);
    return tree.fenAt(tree.endOfLineFrom(const NodePath.root()));
  }

  @override
  bool operator ==(Object other) =>
      other is ChapterHeading &&
      other.draft == draft &&
      other.rootMoves.join(' ') == rootMoves.join(' ');

  @override
  int get hashCode => Object.hash(draft, rootMoves.join(' '));
}

/// The heading of [text], which is a whole chapter or only the first
/// kilobyte of one: nothing below the first game is looked at either way.
///
/// The root line holds movetext, `1. d4 d5 2. c4`; the numbers are dropped
/// and what is left are the moves. A root line whose moves cannot be played
/// from the start reads as no root, which is what an empty root means too.
ChapterHeading readHeading(String text) {
  var draft = false;
  var root = const <String>[];
  var at = 0;
  while (at < text.length) {
    var end = text.indexOf('\n', at);
    if (end < 0) end = text.length;
    if (isEventLine(text, at, end)) break;
    final line = text.substring(at, end).trim();
    at = end + 1;
    if (line == '// Draft') draft = true;
    if (line.startsWith('// Root:')) {
      root = _sansOf(line.substring('// Root:'.length));
    }
  }
  return ChapterHeading(rootMoves: root, draft: draft);
}

/// The `// Root:` line for [rootMoves], with a newline, or nothing at all
/// for a chapter that starts at the start.
String rootLine(List<String> rootMoves) {
  if (rootMoves.isEmpty) return '';
  final numbered = <String>[];
  final tree = lineTree(Fen.initial, rootMoves);
  var siblings = tree.children;
  while (siblings.isNotEmpty) {
    final node = siblings.first;
    final label = moveNumberLabel(node, startsLine: numbered.isEmpty);
    numbered.add(label.isEmpty ? node.san : '$label ${node.san}');
    siblings = node.children;
  }
  return '// Root: ${numbered.join(' ')}\n';
}

/// The moves of [movetext] that can be played from the start, in order.
List<String> _sansOf(String movetext) {
  final sans = <String>[];
  for (final word in movetext.trim().split(RegExp(r'\s+'))) {
    if (word.isEmpty || RegExp(r'^\d+\.*$').hasMatch(word)) continue;
    sans.add(word.replaceFirst(RegExp(r'^\d+\.+'), ''));
  }
  final playable = mainlineSans(lineTree(Fen.initial, sans));
  return playable.length == sans.length
      ? List.unmodifiable(playable)
      : const [];
}
