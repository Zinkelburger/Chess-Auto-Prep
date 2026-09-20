import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_merge.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game that writes the same reply twice: once as the main move and once
/// as a variation of it. Course exports do this, and so does a file two
/// people edited.
const twiceOverGame = '''
[Event "Twice over"]
[Result "*"]

1. e4 e5 (1... e5 {alt}) 2. Nf3 *
''';

void main() {
  test('one game that plays a move twice keeps one node for it', () {
    final tree = readGame(twiceOverGame).tree!;
    final merged = mergeForests(const [], tree.children);
    final e5 = merged.single.children.single;
    expect(e5.san, 'e5');
    expect(e5.comment, 'alt', reason: 'the variation said something');
    expect(e5.children.single.san, 'Nf3');
  });

  test('a later game adds its variation and reorders nothing', () {
    final first = readGame('1. d4 d5 2. c4 *').tree!;
    final second = readGame('1. d4 Nf6 *').tree!;
    final merged = mergeForests(first.children, second.children);
    expect(merged.single.san, 'd4');
    expect(merged.single.children.map((n) => n.san), ['d5', 'Nf6']);
  });

  test('every move of a merged chapter is found where the tree holds it', () {
    final chapter = parseChapter(name: 'Twice over', text: twiceOverGame);
    final replies = chapter.tree.children.single.children;
    for (final (index, reply) in replies.indexed) {
      expect(
        pathOfSans(chapter.tree, ['e4', reply.san]),
        NodePath.of([0, index]),
        reason: 'a cursor on ${reply.san} has to land on ${reply.san}',
      );
    }
  });
}
