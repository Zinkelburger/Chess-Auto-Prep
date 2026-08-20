import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:flutter_test/flutter_test.dart';

BuildTreeNode _node(String fen, {int id = 1}) => BuildTreeNode(
  fen: fen,
  moveSan: '',
  moveUci: '',
  ply: 0,
  isWhiteToMove: true,
  nodeId: id,
);

void main() {
  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  // A position reached by two move orders: one copy expanded, one not. Which
  // one the DFS meets first is decided by child order, so both orderings have
  // to end up with the expanded copy as canonical.
  ({BuildTreeNode root, BuildTreeNode bare, BuildTreeNode expanded}) twins({
    required bool bareFirst,
  }) {
    const shared = '8/8/8/8/8/8/8/K6k b - - 0 1';
    final root = _node(start, id: 1);
    final bare = _node(shared, id: 2);
    final expanded = _node(shared, id: 3);
    expanded.children.add(_node('8/8/8/8/8/8/8/K5k1 w - - 1 2', id: 4));
    root.children.addAll(bareFirst ? [bare, expanded] : [expanded, bare]);
    return (root: root, bare: bare, expanded: expanded);
  }

  for (final bareFirst in [true, false]) {
    test('the expanded copy wins the canonical slot '
        '(childless copy ${bareFirst ? 'first' : 'second'})', () {
      final t = twins(bareFirst: bareFirst);
      final map = FenMap()..populate(t.root);

      expect(map.getCanonical(t.bare.fen), same(t.expanded));
      expect(map.getTranspositions(t.bare.fen), contains(t.bare));
      // ...so a line arriving at the childless copy continues through the
      // answered one instead of dead-ending there.
      expect(resolveTransposition(t.bare, map), same(t.expanded));
    });
  }

  test('a promoted canonical is not left behind in its own equivalents', () {
    final t = twins(bareFirst: false);
    final map = FenMap()..populate(t.root);
    // The expanded node is registered first, then promoted again on a second
    // pass; it must never end up listed as a transposition of itself.
    map.populate(t.root);

    expect(map.getCanonical(t.bare.fen), same(t.expanded));
    expect(map.getTranspositions(t.bare.fen), isNot(contains(t.expanded)));
    expect(map.getTranspositions(t.bare.fen).length, 1);
  });

  test('two expanded copies keep the first as canonical', () {
    const shared = '8/8/8/8/8/8/8/K6k b - - 0 1';
    final root = _node(start, id: 1);
    final first = _node(shared, id: 2)
      ..children.add(_node('8/8/8/8/8/8/8/K5k1 w - - 1 2', id: 4));
    final second = _node(shared, id: 3)
      ..children.add(_node('8/8/8/8/8/8/8/K5k1 w - - 1 2', id: 5));
    root.children.addAll([first, second]);

    final map = FenMap()..populate(root);
    expect(map.getCanonical(shared), same(first));
  });

  test('freeze rejects mutation but still allows lookup', () {
    final root = _node(start);
    final map = FenMap()..populate(root);
    map.freeze();

    expect(map.isFrozen, isTrue);
    expect(map.getCanonical(start), same(root));
    expect(() => map.clear(), throwsStateError);
    expect(() => map.populate(root), throwsStateError);
    expect(
      () => map.putCanonical(start, _node(start, id: 2)),
      throwsStateError,
    );
  });

  test(
    'isTranspositionCycle only trips when following a transposition leaf',
    () {
      final canonical = _node(start, id: 1);
      final leaf = _node(start, id: 2);
      final visited = <String>{};
      enterFenPath(canonical, visited);

      expect(isTranspositionCycle(canonical, canonical, visited), isFalse);
      expect(isTranspositionCycle(leaf, canonical, visited), isTrue);
      expect(enterPositionOnce(canonical, <String>{}), isTrue);
      expect(enterPositionOnce(canonical, {canonicalizeFen(start)}), isFalse);
    },
  );
}
