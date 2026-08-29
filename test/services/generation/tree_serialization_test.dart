/// Tree serialization: the document form, the iterative walk, and the
/// compact encoding used off the UI isolate.
library;

import 'dart:convert';

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

void main() {
  setUp(resetNodeIds);

  test('compact and indented encodings are the same document', () {
    final t = StandardTree();
    final tree = t.toTree();
    tree.root.explored = true;
    t.e4.pruneReason = PruneReason.evalTooHigh;
    final compact = serializeTree(tree, indent: false);
    final indented = serializeTree(tree);
    expect(compact.contains('\n'), isFalse);
    expect(jsonDecode(compact), jsonDecode(indented));
  });

  test('the document round-trips through deserializeTreeJson', () {
    final source = StandardTree().toTree();
    // A node with children is an explored node; the reader assumes as much
    // for legacy documents that carry no flag, so mark the fixture the same
    // way a real build would.
    void markExplored(BuildTreeNode node) {
      if (node.children.isEmpty) return;
      node.explored = true;
      node.children.forEach(markExplored);
    }

    markExplored(source.root);
    final json = serializeTreeJson(source);
    final back = deserializeTreeJson(json);
    expect(back.totalNodes, source.totalNodes);
    expect(back.root.children.map((c) => c.moveSan), ['e4', 'd4']);
    expect(serializeTreeJson(back), json);
  });

  test('children keep their order, and a deep chain does not recurse', () {
    // Deep enough that a recursive walk would overflow the test stack.
    final root = makeNode(fen: 'r 0 1', san: '', ply: 0, isWhiteToMove: true);
    var node = root;
    for (var i = 1; i <= 20000; i++) {
      node = makeNode(
        fen: 'f$i',
        san: 'm$i',
        ply: i,
        isWhiteToMove: i.isEven,
        parent: node,
      );
    }
    final tree = BuildTree(root: root, totalNodes: 20001);
    final json = serializeTreeJson(tree);
    var depth = 0;
    var cursor = json['tree'] as Map<String, dynamic>;
    while (cursor.containsKey('children')) {
      final children = cursor['children'] as List;
      expect(children, hasLength(1));
      cursor = children.single as Map<String, dynamic>;
      depth++;
    }
    expect(depth, 20000);
  });

  test('serializeTreeInIsolate matches the synchronous encoding', () async {
    final tree = StandardTree().toTree();
    expect(
      await serializeTreeInIsolate(tree, indent: false),
      serializeTree(tree, indent: false),
    );
  });
}
