import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_projection_cache.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/documents/models/move_text_layout.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('annotation revisions reuse rows and match a fresh layout', () {
    final tree = MoveTree.fromPgn(
      '1. e4 {First.} e5 {Reply.} (1... c5 {Other.}) 2. Nf3 *',
    );
    final projection = MoveTreeProjectionCache();
    final cache = MoveTextCommentCache();
    final before = MoveTextLayout.capture(
      projection.read(tree),
      comments: cache,
    );
    final path = TreePath.from([0, 0]);
    tree.setComment(path, '[%eval 0.4]\n\nChanged reply.');
    projection.changed(tree, path: path);
    final snapshot = projection.read(tree);
    final after = before.reviseAnnotations(snapshot, comments: cache)!;
    final fresh = MoveTextLayout.capture(snapshot);
    expect(after.rows.length, fresh.rows.length);
    for (var i = 0; i < fresh.rows.length; i++) {
      final row = after.rows[i];
      final expected = fresh.rows[i];
      expect(row.runtimeType, expected.runtimeType);
      expect(row.key, expected.key);
      expect(row.depth, expected.depth);
      expect(after.indexOfKey(row.key), i);
      if (row is MoveTextRun) {
        for (final move in row.moves) {
          expect(move.node, same(snapshot.nodeAt(move.address.toPath())));
        }
      } else if (row is MoveTextComment) {
        expect(row.text, (expected as MoveTextComment).text);
        if (row.node != null) {
          expect(row.node, same(snapshot.nodeAt(row.address!.toPath())));
        }
      }
    }
    expect(before.rows.whereType<MoveTextComment>().map((r) => r.text), [
      'First.',
      'Reply.',
      'Other.',
    ]);
    final unchanged = before.rows.whereType<MoveTextComment>().last;
    expect(after.rows[after.indexOfKey(unchanged.key)!], same(unchanged));
    tree.setComment(path, 'Two.\n\nParagraphs.');
    projection.changed(tree, path: path);
    expect(
      after.reviseAnnotations(projection.read(tree), comments: cache),
      isNull,
    );
    tree.roots.add(MoveNode(san: 'd4', fen: kStandardStartFen));
    projection.changed(tree);
    expect(
      after.reviseAnnotations(projection.read(tree), comments: cache),
      isNull,
    );
  });

  test('row keys resolve prose, root notes, hidden moves and editors', () {
    final tree = MoveTree.fromPgn(
      '{Root.\n\nMore root.} 1. e4 {First.\n\n[%eval 0.4]\n\nThird.} '
      'e5 (1... c5 {Variation.}) 2. Nf3 *',
    );
    final hidden = MoveNode(
      san: '--',
      fen: kStandardStartFen,
      comment: 'Hidden.\n\nSecond hidden.',
    );
    tree.roots.add(hidden);
    for (final editing in [null, tree.roots.first.id, hidden.id]) {
      final layout = MoveTextLayout.capture(tree, editingNodeId: editing);
      for (final (index, row) in layout.rows.indexed) {
        expect(layout.indexOfKey(row.key), index);
      }
      expect(layout.indexOfKey(('comment', tree.roots.first.id, 99)), isNull);
      expect(layout.indexOfKey(('comment', null, 99)), isNull);
      expect(layout.indexOfKey(('moves', hidden.id)), isNull);
      expect(layout.indexOfKey(('editor', -1)), isNull);
      expect(layout.indexOfKey(Object()), isNull);
      expect(() => layout.rows.clear(), throwsUnsupportedError);
    }
  });

  test('comment cache reuses prose but invalidates mutable annotations', () {
    final tree = MoveTree.fromPgn(
      '1. e4 {First.\n\n[%eval 0.4]\n\nThird.} e5 *',
    );
    final node = tree.roots.single;
    final cache = MoveTextCommentCache();
    final original = cache.paragraphs(node, node.comment!);
    expect(original, [(index: 0, text: 'First.'), (index: 2, text: 'Third.')]);
    expect(cache.paragraphs(node, node.comment!), same(original));
    final before = MoveTextLayout.capture(tree, comments: cache);
    tree.setComment(TreePath.from([0]), 'Changed.');
    final after = MoveTextLayout.capture(tree, comments: cache);
    expect(before.rows.whereType<MoveTextComment>().map((row) => row.text), [
      'First.',
      'Third.',
    ]);
    expect(after.rows.whereType<MoveTextComment>().single.text, 'Changed.');
    tree.setComment(TreePath.from([0]), '[%eval 0.4]');
    expect(
      MoveTextLayout.capture(
        tree,
        comments: cache,
      ).rows.whereType<MoveTextComment>(),
      isEmpty,
    );
    expect(original, [(index: 0, text: 'First.'), (index: 2, text: 'Third.')]);
    expect(() => original.clear(), throwsUnsupportedError);
  });

  test('variation order, paths, prose and resumed black numbering survive', () {
    final tree = MoveTree.fromPgn(
      '1. e4 {First.\n\nSecond.} (1. d4 d5 (1... Nf6) 2. c4) e5 *',
    );
    final layout = MoveTextLayout.capture(tree);
    final runs = layout.rows.whereType<MoveTextRun>().toList();
    expect(runs.expand((r) => r.moves).map((m) => m.node.san), [
      'e4',
      'd4',
      'd5',
      'Nf6',
      'c4',
      'e5',
    ]);
    for (final row in runs) {
      for (final move in row.moves) {
        expect(tree.nodeAt(move.address.toPath()), same(move.node));
        expect(layout.rows[layout.rowForNode(move.node.id)!], same(row));
      }
    }
    expect(runs.last.moves.single.showNumber, isTrue);
    expect(runs.last.moves.single.white, isFalse);
    expect(runs.last.moves.single.number, 1);
    expect(layout.rows.whereType<MoveTextComment>().map((r) => r.text), [
      'First.',
      'Second.',
    ]);
    expect(runs.map((r) => r.depth), [0, 1, 2, 1, 0]);
  });

  test('20000-ply indexing is iterative and paths materialize on demand', () {
    final tree = MoveTree();
    var children = tree.roots;
    for (var i = 0; i < 20000; i++) {
      final node = MoveNode(
        san: i.isEven ? 'Nf3' : 'Nf6',
        fen: kStandardStartFen,
      );
      children.add(node);
      children = node.children;
    }
    final watch = Stopwatch()..start();
    final layout = MoveTextLayout.capture(tree);
    watch.stop();
    expect(layout.rows.length, (20000 / 24).ceil());
    final last = (layout.rows.last as MoveTextRun).moves.last;
    expect(last.address.length, 20000);
    expect(last.address.toPath(), TreePath.from(List.filled(20000, 0)));
    expect(
      layout.rows.whereType<MoveTextRun>().every((r) => r.moves.length <= 24),
      isTrue,
    );
    // Diagnostic only; timing is not a correctness assertion.
    // ignore: avoid_print
    print('20000-ply movetext index: ${watch.elapsedMicroseconds} us');
  });

  test('black-to-move starts and chunk boundaries always carry a number', () {
    final tree = MoveTree(startingFen: '8/8/8/8/8/8/4k3/6K1 b - - 0 42');
    var children = tree.roots;
    for (var i = 0; i < 5; i++) {
      final node = MoveNode(san: 'Kd3', fen: tree.startingFen);
      children.add(node);
      children = node.children;
    }
    final layout = MoveTextLayout.capture(tree, maxMovesPerRow: 3);
    final moves = layout.rows
        .whereType<MoveTextRun>()
        .expand((r) => r.moves)
        .toList();
    expect(moves.map((m) => m.number), [42, 43, 43, 44, 44]);
    expect(moves.first.white, isFalse);
    expect(moves.first.showNumber, isTrue);
    expect(moves[3].showNumber, isTrue);
  });

  test(
    'machine-only comments do not break runs and null moves remain hidden',
    () {
      final tree = MoveTree();
      final first = MoveNode(
        san: 'e4',
        fen: kStandardStartFen,
        comment: '[%cal Ge2e4]',
      );
      final hidden = MoveNode(
        san: '--',
        fen: kStandardStartFen,
        comment: 'Position note.',
      );
      first.children.add(hidden);
      tree.roots.add(first);
      final layout = MoveTextLayout.capture(tree);
      expect(
        layout.rows
            .whereType<MoveTextRun>()
            .expand((r) => r.moves)
            .map((m) => m.node.san),
        ['e4'],
      );
      expect(
        layout.rows.whereType<MoveTextComment>().single.text,
        'Position note.',
      );
      expect(layout.rowForNode(hidden.id), 1);
    },
  );
}
