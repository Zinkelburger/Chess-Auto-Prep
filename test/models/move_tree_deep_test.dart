import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('20000 legal plies parse and adopt without recursive stack growth', () {
    final pgn = StringBuffer('[Event "Deep line"]\n\n{Introduction}\n');
    const moves = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
    for (var i = 0; i < 20000; i++) {
      if (i.isEven) pgn.write('${i ~/ 2 + 1}. ');
      pgn.write('${moves[i % 4]} ');
      if (i % 100 == 0) pgn.write('{Note $i} \$1 ');
    }
    pgn.write('*');
    final tree = MoveTree.fromPgn(pgn.toString());
    final end = TreePath.from(List.filled(20000, 0));
    expect(tree.mainlineEndFrom(TreePath.empty).length, end.length);
    final copy = tree.copyWithFreshIds();
    expect(copy.mainlineEndFrom(TreePath.empty).length, end.length);
    expect(copy.fenAt(end), tree.fenAt(end));
    expect(copy.rootComment, 'Introduction');
    final ids = <int>{};
    var originals = tree.roots;
    var adopted = copy.roots;
    var count = 0;
    while (originals.isNotEmpty) {
      final first = originals.single;
      final second = adopted.single;
      expect(ids.add(first.id), isTrue);
      expect(ids.add(second.id), isTrue);
      expect(second.comment, first.comment);
      expect(second.nags, first.nags);
      expect(second.position, same(first.position));
      originals = first.children;
      adopted = second.children;
      count++;
    }
    expect(count, 20000);
    copy.roots.first.nags!.add(2);
    expect(tree.roots.first.nags, [1]);
    expect(copy.toPgnMoveText(), contains('Note 19900'));
  });
}
