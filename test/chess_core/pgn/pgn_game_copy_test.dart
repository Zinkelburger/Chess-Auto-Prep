import 'package:chess_auto_prep/chess_core/pgn/pgn_game_copy.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parsed adoption detaches deep trees and preserves sibling order', () {
    final root = PgnNode<PgnNodeData>();
    var parent = root;
    for (var i = 0; i < 20000; i++) {
      final child = PgnChildNode(
        PgnNodeData(
          san: 'move-$i',
          comments: ['after-$i'],
          startingComments: ['before-$i'],
          nags: [1],
        ),
      );
      parent.children.addAll([
        child,
        PgnChildNode(PgnNodeData(san: 'alternative-$i')),
      ]);
      parent = child;
    }
    final source = PgnGame(
      headers: {'Event': 'Original'},
      comments: ['Introduction'],
      moves: root,
    );
    final copy = copyParsedPgn(source);
    source.headers['Event'] = 'Changed';
    source.comments.clear();
    expect(copy.headers, {'Event': 'Original'});
    expect(copy.comments, ['Introduction']);
    var originalParent = root;
    var copiedParent = copy.moves;
    for (var i = 0; i < 20000; i++) {
      final original = originalParent.children.first;
      final copied = copiedParent.children.first;
      expect(copiedParent.children.map((node) => node.data.san), [
        'move-$i',
        'alternative-$i',
      ]);
      original.data.comments!.clear();
      original.data.startingComments!.clear();
      original.data.nags!.clear();
      expect(copied.data.comments, ['after-$i']);
      expect(copied.data.startingComments, ['before-$i']);
      expect(copied.data.nags, [1]);
      originalParent.children.clear();
      originalParent = original;
      copiedParent = copied;
    }
    expect(copiedParent.children, isEmpty);
  });
}
