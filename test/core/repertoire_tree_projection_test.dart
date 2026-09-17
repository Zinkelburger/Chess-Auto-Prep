import '../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RepertoireController controller;
  setUp(() => controller = testRepertoireController());
  tearDown(() => controller.dispose());

  void load() => controller.loadAnnotatedTree(
    MoveTree.fromPgn('{Introduction} 1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *'),
  );

  test('adoption detaches caller nodes, annotations and root position', () {
    final source = MoveTree.fromPgn('{Intro} 1. e4 \$1 {Original} e5 *');
    controller.loadAnnotatedTree(source, cursor: const TreePath([0]));
    final before = controller.tree;
    final fen = controller.fen;
    source.roots.first.nags!.add(7);
    source.roots.first.children.clear();
    source.setComment(const TreePath([0]), 'Caller mutation');
    source.rootComment = 'Changed intro';
    source.roots.clear();
    expect(controller.tree, same(before));
    expect(controller.fen, fen);
    expect(controller.tree.rootComment, 'Intro');
    expect(controller.tree.roots.single.comment, 'Original');
    expect(controller.tree.roots.single.nags, [1]);
    expect(controller.tree.roots.single.children.single.san, 'e5');
    controller.goForward();
    expect(controller.moveHistory, ['e4', 'e5']);
  });

  test(
    'read values cannot mutate draft and prior revisions remain detached',
    () {
      load();
      final before = controller.tree;
      expect(() => before.roots.clear(), throwsUnsupportedError);
      expect(
        () => before.roots.single.children.clear(),
        throwsUnsupportedError,
      );
      controller.setCommentAtPath(const TreePath([0]), 'New');
      controller.toggleNagAtPath(const TreePath([0]), 1);
      final after = controller.tree;
      expect(after, isA<MoveTreeSnapshot>());
      expect(after, isNot(same(before)));
      expect(after.identity, same(before.identity));
      expect(before.roots.single.comment, isNull);
      expect(before.roots.single.nags, isNull);
      expect(after.roots.single.comment, 'New');
      expect(after.roots.single.nags, [1]);
      expect(() => after.roots.single.nags!.add(2), throwsUnsupportedError);
      expect(
        after.roots.single.children.first,
        same(before.roots.single.children.first),
      );
    },
  );

  test('cursor moves and no-op edits keep the cached projection', () {
    load();
    final tree = controller.tree;
    controller.goToStart();
    controller.playMove('e4');
    controller.goForward();
    controller.goBack();
    controller.setCommentAtPath(const TreePath([0]), null);
    expect(controller.tree, same(tree));
    controller.setCommentAtPath(TreePath.empty, 'Revised introduction');
    final annotated = controller.tree;
    expect(annotated.rootComment, 'Revised introduction');
    expect(annotated.roots.single, same(tree.roots.single));
    expect(tree.rootComment, 'Introduction');
  });

  test(
    'batched edits share untouched branches and notify with fresh views',
    () {
      load();
      final before = controller.tree;
      controller.setCommentAtPath(const TreePath([0, 0]), 'Main');
      controller.setCommentAtPath(const TreePath([0, 1]), 'Side');
      final changed = controller.tree;
      expect(changed.nodeAt(const TreePath([0, 0]))!.comment, 'Main');
      expect(changed.nodeAt(const TreePath([0, 1]))!.comment, 'Side');
      expect(
        changed.nodeAt(const TreePath([0, 0, 0])),
        same(before.nodeAt(const TreePath([0, 0, 0]))),
      );
      MoveTreeSnapshot? delivered;
      controller.addListener(() => delivered = controller.tree);
      controller.playMoveAtTreePath(const TreePath([0, 1, 0]), 'd6');
      expect(delivered!.sanSequenceAt(controller.path), [
        'e4',
        'c5',
        'Nf3',
        'd6',
      ]);
      expect(
        delivered!.nodeAt(const TreePath([0, 0])),
        same(changed.nodeAt(const TreePath([0, 0]))),
      );
    },
  );

  test(
    'promotion and deletion preserve old values and draft undo restores',
    () async {
      load();
      final before = controller.tree;
      controller.jump(const TreePath([0, 1, 0]));
      controller.makeMainLine(controller.path);
      final promoted = controller.tree;
      expect(promoted.roots.single.children.first.san, 'c5');
      expect(
        promoted.roots.single.children.first,
        same(before.roots.single.children[1]),
      );
      expect(controller.moveHistory, ['e4', 'c5', 'Nf3']);
      controller.deleteAtPath(const TreePath([0, 1]));
      expect(controller.tree.roots.single.children, hasLength(1));
      expect(promoted.roots.single.children, hasLength(2));
      expect(await controller.writer.undo(), isTrue);
      expect(controller.tree.toPgnMoveText(), promoted.toPgnMoveText());
      expect(before.roots.single.children.first.san, 'e5');
    },
  );

  test(
    'line entry classifies added moves as structure even with unchanged cursor',
    () {
      controller.loadMoveHistory(['e4']);
      final before = controller.tree;
      final version = controller.structureVersion;
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.navigateToLineMove(['e4', 'e5'], targetIndex: 0);
      expect(controller.structureVersion, greaterThan(version));
      expect(notifications, 1);
      expect(controller.path, const TreePath([0]));
      expect(controller.tree.roots.single.children.single.san, 'e5');
      expect(before.roots.single.children, isEmpty);
      final grown = controller.tree;
      controller.navigateToLineMove(['e4', 'e5']);
      expect(controller.tree, same(grown));
      controller.applyLineFromCurrent(['Nf3', 'Nc6'], 0);
      expect(controller.tree.sanSequenceAt(controller.path), [
        'e4',
        'e5',
        'Nf3',
      ]);
      expect(controller.tree.nodeAt(const TreePath([0, 0, 0, 0]))!.san, 'Nc6');
    },
  );

  test(
    'replacement rotates editing identity and close revision stays opaque',
    () {
      load();
      final before = controller.tree;
      controller.loadAnnotatedTree(MoveTree.fromPgn(before.toPgnMoveText()));
      expect(controller.tree.identity, isNot(same(before.identity)));
      expect(controller.tree.roots.single.id, isNot(before.roots.single.id));
      final revision =
          controller.closeRevision
              as (String?, int, Future<void>, Object?, Object?, Object, int);
      expect(revision.$6, same(controller.tree.identity));
      expect(revision.$6, isNot(isA<MoveTree>()));
    },
  );
}
