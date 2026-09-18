import '../../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BuilderWorkspaceController controller;
  setUp(() => controller = testBuilderWorkspace());
  tearDown(() => controller.dispose());

  void load() => controller.inspectAnnotatedTree(
    MoveTree.fromPgn('{Introduction} 1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *'),
  );

  test('adoption detaches caller nodes, annotations and root position', () {
    final source = MoveTree.fromPgn('{Intro} 1. e4 \$1 {Original} e5 *');
    controller.inspectAnnotatedTree(source, cursor: const TreePath([0]));
    final before = controller.board.tree;
    final fen = controller.board.fen;
    source.roots.first.nags!.add(7);
    source.roots.first.children.clear();
    source.setComment(const TreePath([0]), 'Caller mutation');
    source.rootComment = 'Changed intro';
    source.roots.clear();
    expect(controller.board.tree, same(before));
    expect(controller.board.fen, fen);
    expect(controller.board.tree.rootComment, 'Intro');
    expect(controller.board.tree.roots.single.comment, 'Original');
    expect(controller.board.tree.roots.single.nags, [1]);
    expect(controller.board.tree.roots.single.children.single.san, 'e5');
    controller.board.goForward();
    expect(controller.board.moveHistory, ['e4', 'e5']);
  });

  test(
    'read values cannot mutate draft and prior revisions remain detached',
    () {
      load();
      final before = controller.board.tree;
      expect(() => before.roots.clear(), throwsUnsupportedError);
      expect(
        () => before.roots.single.children.clear(),
        throwsUnsupportedError,
      );
      controller.board.setCommentAtPath(const TreePath([0]), 'New');
      controller.board.toggleNagAtPath(const TreePath([0]), 1);
      final after = controller.board.tree;
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
    final tree = controller.board.tree;
    controller.board.goToStart();
    controller.board.playMove('e4');
    controller.board.goForward();
    controller.board.goBack();
    controller.board.setCommentAtPath(const TreePath([0]), null);
    expect(controller.board.tree, same(tree));
    controller.board.setCommentAtPath(TreePath.empty, 'Revised introduction');
    final annotated = controller.board.tree;
    expect(annotated.rootComment, 'Revised introduction');
    expect(annotated.roots.single, same(tree.roots.single));
    expect(tree.rootComment, 'Introduction');
  });

  test(
    'batched edits share untouched branches and notify with fresh views',
    () {
      load();
      final before = controller.board.tree;
      controller.board.setCommentAtPath(const TreePath([0, 0]), 'Main');
      controller.board.setCommentAtPath(const TreePath([0, 1]), 'Side');
      final changed = controller.board.tree;
      expect(changed.nodeAt(const TreePath([0, 0]))!.comment, 'Main');
      expect(changed.nodeAt(const TreePath([0, 1]))!.comment, 'Side');
      expect(
        changed.nodeAt(const TreePath([0, 0, 0])),
        same(before.nodeAt(const TreePath([0, 0, 0]))),
      );
      MoveTreeSnapshot? delivered;
      controller.addListener(() => delivered = controller.board.tree);
      controller.board.playMoveAtTreePath(const TreePath([0, 1, 0]), 'd6');
      expect(delivered!.sanSequenceAt(controller.board.path), [
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
      final before = controller.board.tree;
      controller.board.jump(const TreePath([0, 1, 0]));
      controller.board.makeMainLine(controller.board.path);
      final promoted = controller.board.tree;
      expect(promoted.roots.single.children.first.san, 'c5');
      expect(
        promoted.roots.single.children.first,
        same(before.roots.single.children[1]),
      );
      expect(controller.board.moveHistory, ['e4', 'c5', 'Nf3']);
      controller.deleteDraftBranch(const TreePath([0, 1]));
      expect(controller.board.tree.roots.single.children, hasLength(1));
      expect(promoted.roots.single.children, hasLength(2));
      expect(await controller.writer.undo(), isTrue);
      expect(controller.board.tree.toPgnMoveText(), promoted.toPgnMoveText());
      expect(before.roots.single.children.first.san, 'e5');
    },
  );

  test(
    'line entry classifies added moves as structure even with unchanged cursor',
    () {
      controller.board.loadMoveHistory(['e4']);
      final before = controller.board.tree;
      final version = controller.structureVersion;
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.board.navigateToLineMove(['e4', 'e5'], targetIndex: 0);
      expect(controller.structureVersion, greaterThan(version));
      expect(notifications, 1);
      expect(controller.board.path, const TreePath([0]));
      expect(controller.board.tree.roots.single.children.single.san, 'e5');
      expect(before.roots.single.children, isEmpty);
      final grown = controller.board.tree;
      controller.board.navigateToLineMove(['e4', 'e5']);
      expect(controller.board.tree, same(grown));
      controller.board.applyLineFromCurrent(['Nf3', 'Nc6'], 0);
      expect(controller.board.tree.sanSequenceAt(controller.board.path), [
        'e4',
        'e5',
        'Nf3',
      ]);
      expect(
        controller.board.tree.nodeAt(const TreePath([0, 0, 0, 0]))!.san,
        'Nc6',
      );
    },
  );

  test(
    'replacement rotates editing identity and recovery close revision tracks cursor',
    () {
      load();
      final before = controller.board.tree;
      final beforeRevision = controller.closeRevision;
      controller.board.goToStart();
      expect(controller.closeRevision, isNot(beforeRevision));
      controller.inspectAnnotatedTree(MoveTree.fromPgn(before.toPgnMoveText()));
      expect(controller.board.tree.identity, isNot(same(before.identity)));
      expect(
        controller.board.tree.roots.single.id,
        isNot(before.roots.single.id),
      );
      expect(controller.closeRevision, isNot(beforeRevision));
      final adoptedRevision = controller.closeRevision;
      controller.board.setCommentAtPath(TreePath.empty, 'Changed introduction');
      expect(controller.closeRevision, isNot(adoptedRevision));
      expect(controller.board.tree.identity, isNot(isA<MoveTree>()));
    },
  );
}
