import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_board_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'navigation exposes coherent immutable paths without changing the tree',
    () {
      final board = RepertoireBoardController()..loadMoveHistory(['e4', 'c5']);
      final tree = board.tree;
      final history = board.moveHistory;
      final fens = board.cursorFens;
      final structure = board.structureVersion;
      expect(fens.last, board.fen);
      expect(board.position.fen, board.fen);
      expect(() => fens.clear(), throwsUnsupportedError);
      board.goBack();
      expect(board.moveHistory, ['e4']);
      expect(history, ['e4', 'c5']);
      expect(board.cursorFens, fens.take(1));
      expect(board.tree, same(tree));
      expect(board.structureVersion, structure);
      final revision = board.revision;
      board.jump(const TreePath([99]));
      expect(board.revision, revision);
    },
  );

  test('draft undo rejects another adoption even when movetext matches', () {
    final board = RepertoireBoardController()..loadMoveHistory(['e4', 'e5']);
    final edit = board.deleteAtPath(const TreePath([0, 0]))!;
    expect(board.canRestore(edit), isTrue);
    board.loadMoveHistory(['e4']);
    final adopted = board.tree;
    expect(board.canRestore(edit), isFalse);
    expect(board.restore(edit), isFalse);
    expect(board.tree, same(adopted));
    expect(board.moveHistory, ['e4']);
  });

  test('successive draft undos restore annotations, variations and cursor', () {
    final board = RepertoireBoardController()
      ..loadAnnotatedTree(
        MoveTree.fromPgn('{Intro} 1. e4 \$1 {Keep} e5 (1... c5) 2. Nf3 *'),
      );
    final before = board.tree.toPgnMoveText();
    final cursor = board.path;
    final first = board.deleteAtPath(const TreePath([0, 0, 0]))!;
    final second = board.deleteAtPath(const TreePath([0, 1]))!;
    expect(board.canRestore(first), isFalse);
    expect(board.restore(second), isTrue);
    expect(board.restore(first), isTrue);
    expect(board.tree.toPgnMoveText(), before);
    expect(board.path, cursor);
    expect(board.tree.rootComment, 'Intro');
    expect(board.tree.roots.single.nags, [1]);
  });

  test(
    'invalid deletion is inert; root deletion clears and restores the game',
    () {
      final board = RepertoireBoardController()..loadMoveHistory(['e4']);
      final revision = board.revision;
      expect(board.deleteAtPath(const TreePath([2])), isNull);
      expect(board.revision, revision);
      expect(board.moveHistory, ['e4']);
      final cleared = board.deleteAtPath(TreePath.empty)!;
      expect(board.tree.isEmpty, isTrue);
      expect(board.moveHistory, isEmpty);
      expect(board.restore(cleared), isTrue);
      expect(board.moveHistory, ['e4']);
    },
  );

  test('failed position adoption retains the editing lifetime and receipt', () {
    final board = RepertoireBoardController()..loadMoveHistory(['e4', 'e5']);
    final edit = board.deleteAtPath(const TreePath([0, 0]))!;
    final revision = board.revision;
    expect(board.setPositionFromFen('invalid'), isFalse);
    expect(
      board.setPositionFromMoveHistory(
        fen: Chess.initial.fen,
        moves: ['d4'],
        startingFen: 'invalid',
      ),
      isFalse,
    );
    expect(board.revision, revision);
    expect(board.restore(edit), isTrue);
    expect(board.moveHistory, ['e4', 'e5']);
  });

  test('root navigation resets prior paths and classifies inserted moves', () {
    final board = RepertoireBoardController()..loadMoveHistory(['e4', 'e5']);
    final structure = board.structureVersion;
    board.navigateToRootPosition('1. d4 d5');
    expect(board.structureVersion, greaterThan(structure));
    expect(board.moveHistory, ['d4', 'd5']);
    expect(board.isAtRootPosition('1. d4 d5'), isTrue);
    final rootFen = board.rootFen('1. d4 d5');
    expect(board.rootFen('1. d4 d5'), same(rootFen));
    board.navigateToRootPosition('');
    expect(board.moveHistory, isEmpty);
    expect(board.fen, Chess.initial.fen);
  });
}
