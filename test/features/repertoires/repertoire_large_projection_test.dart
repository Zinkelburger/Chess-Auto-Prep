import '../../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/large_study_fixture.dart';

void main() {
  test(
    '20000-node Builder adoption shares untouched branches on a deep annotation',
    () {
      final controller = testBuilderWorkspace();
      addTearDown(controller.dispose);
      final source = MoveTree.fromPgn(largeStudyPgn());
      controller.inspectAnnotatedTree(source);
      final watch = Stopwatch()..start();
      final initial = controller.board.tree;
      watch.stop();
      final initialMicros = watch.elapsedMicroseconds;
      final target = TreePath([99, ...List.filled(199, 0)]);
      watch
        ..reset()
        ..start();
      controller.board.setCommentAtPath(target, 'Updated final note');
      final changed = controller.board.tree;
      watch.stop();
      // ignore: avoid_print
      print(
        'Builder 20000-node projection: initial $initialMicros us; deep edit ${watch.elapsedMicroseconds} us',
      );
      expect(changed.nodeAt(target)!.comment, 'Updated final note');
      expect(initial.nodeAt(target)!.comment, contains('Branch 99 move 199'));
      for (var i = 0; i < 99; i++) {
        expect(changed.roots[i], same(initial.roots[i]));
      }
      controller.board.jump(target);
      expect(controller.board.tree, same(changed));
      source.roots.clear();
      expect(controller.board.tree.roots, hasLength(100));
    },
  );
}
