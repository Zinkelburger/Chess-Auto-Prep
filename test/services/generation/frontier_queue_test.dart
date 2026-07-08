// Best-first frontier: max-heap on searchPriority with deterministic
// tiebreaks, FIFO fallback, and the legacy priority fallback to
// cumulativeProbability.

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/frontier_queue.dart';
import 'package:flutter_test/flutter_test.dart';

int _idCounter = 0;

BuildTreeNode _node({
  double priority = -1.0,
  double cumP = 1.0,
  int ply = 0,
}) {
  final n = BuildTreeNode(
    fen: 'fen-${++_idCounter}',
    moveSan: 'e4',
    moveUci: 'e2e4',
    ply: ply,
    isWhiteToMove: true,
    nodeId: _idCounter,
    cumulativeProbability: cumP,
  );
  n.searchPriority = priority;
  return n;
}

void main() {
  group('FrontierQueue best-first', () {
    test('pops highest searchPriority first', () {
      final q = FrontierQueue(bestFirst: true);
      final low = _node(priority: 0.1);
      final high = _node(priority: 0.9);
      final mid = _node(priority: 0.5);
      q.addAll([low, high, mid]);

      expect(q.removeFirst(), same(high));
      expect(q.removeFirst(), same(mid));
      expect(q.removeFirst(), same(low));
      expect(q.isEmpty, isTrue);
    });

    test('unset priority falls back to cumulativeProbability', () {
      final q = FrontierQueue(bestFirst: true);
      final legacy = _node(priority: -1.0, cumP: 0.8);
      final explicit = _node(priority: 0.5);
      q.addAll([explicit, legacy]);

      expect(q.removeFirst(), same(legacy));
      expect(q.removeFirst(), same(explicit));
    });

    test('ties break toward shallower ply then lower nodeId', () {
      final q = FrontierQueue(bestFirst: true);
      final deep = _node(priority: 0.5, ply: 8);
      final shallow = _node(priority: 0.5, ply: 2);
      q.addAll([deep, shallow]);
      expect(q.removeFirst(), same(shallow));

      final a = _node(priority: 0.5, ply: 4);
      final b = _node(priority: 0.5, ply: 4);
      q.addAll([b, a]);
      expect(q.removeFirst().nodeId, lessThan(q.removeFirst().nodeId));
    });

    test('heap survives interleaved add/remove', () {
      final q = FrontierQueue(bestFirst: true);
      for (final p in [0.3, 0.9, 0.1, 0.7, 0.5]) {
        q.add(_node(priority: p));
      }
      expect(effectiveSearchPriority(q.removeFirst()), 0.9);
      q.add(_node(priority: 0.8));
      q.add(_node(priority: 0.2));
      final popped = <double>[];
      while (q.isNotEmpty) {
        popped.add(effectiveSearchPriority(q.removeFirst()));
      }
      expect(popped, [0.8, 0.7, 0.5, 0.3, 0.2, 0.1]);
    });
  });

  group('FrontierQueue FIFO', () {
    test('preserves insertion order regardless of priority', () {
      final q = FrontierQueue(bestFirst: false);
      final first = _node(priority: 0.1);
      final second = _node(priority: 0.9);
      q.addAll([first, second]);
      expect(q.removeFirst(), same(first));
      expect(q.removeFirst(), same(second));
    });
  });
}
