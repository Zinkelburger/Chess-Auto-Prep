import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot round-trips annotations, variations and setup positions', () {
    final tree = MoveTree.fromPgn(
      '[Event "Example"]\n\n{Intro} 1. e4 \$1 {main} '
      '({Before variation} 1. d4 d5) e5 *',
    );
    final snapshot = MoveTreeSnapshot.capture(tree);
    expect(snapshot.toPgnMoveText(), tree.toPgnMoveText());
    tree.setComment(const TreePath([0]), 'new');
    tree.clearVariations();
    expect(snapshot.roots, hasLength(2));
    expect(snapshot.commentAt(const TreePath([0])), 'main');
    expect(snapshot.roots.first.nags, [1]);
    expect(snapshot.roots.last.startingComment, 'Before variation');
  });

  test('deep and wide 20000-node snapshots have no recursive copy limit', () {
    for (final deep in [false, true]) {
      final roots = <MoveNode>[];
      var children = roots;
      for (var i = 0; i < 20000; i++) {
        final node = MoveNode(san: 'Nf3', fen: kStandardStartFen, nags: [1]);
        children.add(node);
        if (deep) children = node.children;
      }
      final source = MoveTree(roots: roots);
      final watch = Stopwatch()..start();
      final snapshot = MoveTreeSnapshot.capture(source);
      watch.stop();
      // Diagnostic measurement, not a host-speed-dependent test threshold.
      // ignore: avoid_print
      print(
        'Snapshot 20000 ${deep ? "deep" : "wide"} nodes: '
        '${watch.elapsedMicroseconds} us',
      );
      final pending = snapshot.roots.toList();
      var count = 0;
      while (pending.isNotEmpty) {
        final node = pending.removeLast();
        count++;
        pending.addAll(node.children);
      }
      expect(count, 20000);
      source.roots.first.nags!.clear();
      source.roots.clear();
      expect(snapshot.roots.first.nags, [1]);
    }
  });

  test('local edits reuse 19999 unchanged nodes in a large branching tree', () {
    // A long mainline under each root makes copying descendants expensive,
    // while a local annotation only needs the affected ancestor chain.
    final roots = <MoveNode>[];
    for (var branch = 0; branch < 100; branch++) {
      var children = roots;
      for (var ply = 0; ply < 200; ply++) {
        final node = MoveNode(san: 'Nf3', fen: kStandardStartFen);
        children.add(node);
        children = node.children;
      }
    }
    final source = MoveTree(roots: roots);
    var previous = MoveTreeSnapshot.capture(source);
    final original = previous;
    final watch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      source.setComment(const TreePath([0]), 'edit $i');
      final next = MoveTreeSnapshot.revise(
        source,
        previous: previous,
        changedNodeIds: {source.roots.first.id},
      );
      expect(
        next.roots.first.children.first,
        same(previous.roots.first.children.first),
      );
      for (var branch = 1; branch < 100; branch++) {
        expect(next.roots[branch], same(previous.roots[branch]));
      }
      previous = next;
    }
    watch.stop();
    // ignore: avoid_print
    print(
      '100 local edits in 20000-node tree: ${watch.elapsedMicroseconds} us',
    );
    expect(original.roots.first.comment, isNull);
    expect(previous.roots.first.comment, 'edit 99');
  });
}
