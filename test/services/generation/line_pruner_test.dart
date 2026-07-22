import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

/// Line whose SAN list is just a label; only coverage units and probability
/// matter to the pruner.
ExtractedLine _line(
  String name,
  double probability,
  List<(String, double)> units,
) {
  return ExtractedLine(
    movesSan: [name],
    movesUci: [name],
    probability: probability,
    coverageUnits: [
      for (final (key, value) in units)
        LineCoverageUnit(key: key, value: value),
    ],
  );
}

String _name(ExtractedLine l) => l.movesSan.single;

void main() {
  group('LinePruner', () {
    test('targetCount <= 0 disables pruning', () {
      final lines = [
        _line('a', 0.5, [('e2e4', 1.0)]),
        _line('b', 0.5, [('e2e4', 1.0)]),
      ];
      expect(LinePruner.prune(lines, targetCount: 0), same(lines));
      expect(LinePruner.prune(lines, targetCount: -1), same(lines));
    });

    test('lines with identical our-move projections collapse to one', () {
      // Same keys = we play the same moves; only opponent moves differ.
      final lines = [
        _line('likely', 0.5, [('e2e4', 1.0), ('e2e4 g1f3', 0.8)]),
        _line('rare', 0.2, [('e2e4', 1.0), ('e2e4 g1f3', 0.3)]),
      ];
      final kept = LinePruner.prune(lines, targetCount: 10);
      expect(kept.map(_name), ['likely']);
    });

    test('greedy picks highest-value coverage under the target cap', () {
      final lines = [
        _line('dull', 0.9, [('a', 0.1)]),
        _line('sharp', 0.3, [('b', 1.0), ('b c', 1.0)]),
        _line('medium', 0.5, [('d', 0.5)]),
      ];
      final kept = LinePruner.prune(lines, targetCount: 2);
      // 'sharp' has the largest total value, 'medium' the next marginal.
      expect(kept.map(_name), ['sharp', 'medium']);
    });

    test('shared prefixes count once; distinct suffixes both survive', () {
      final lines = [
        _line('main', 0.6, [
          ('nf6', 1.0),
          ('nf6 g6', 0.9),
          ('nf6 g6 re8', 0.5),
        ]),
        _line('deviation', 0.3, [
          ('nf6', 1.0),
          ('nf6 g6', 0.9),
          ('nf6 g6 nh5', 0.4),
        ]),
        _line('duplicate', 0.1, [
          ('nf6', 1.0),
          ('nf6 g6', 0.9),
          ('nf6 g6 re8', 0.2),
        ]),
      ];
      final kept = LinePruner.prune(lines, targetCount: 10);
      // 'deviation' teaches a new response (...Nh5); 'duplicate' repeats
      // 'main' move for move and is dropped despite the target allowing it.
      expect(kept.map(_name), ['main', 'deviation']);
    });

    test('stops below target when nothing new remains', () {
      final lines = [
        _line('a', 0.5, [('x', 1.0)]),
        _line('b', 0.4, [('x', 0.9)]),
        _line('c', 0.3, [('x', 0.8)]),
      ];
      expect(LinePruner.prune(lines, targetCount: 3).length, 1);
    });

    test('drops lines with no our-moves to teach', () {
      final lines = [
        _line('teaches', 0.5, [('e2e4', 1.0)]),
        _line('empty', 0.9, []),
      ];
      final kept = LinePruner.prune(lines, targetCount: 5);
      expect(kept.map(_name), ['teaches']);
    });

    test('collapses extracted lines that differ only in opponent moves', () {
      final t = StandardTree();
      t.e4.isRepertoireMove = true;
      t.e4e5nf3.isRepertoireMove = true;
      t.e4c5nf3.isRepertoireMove = true;
      t.e4e5nf3.cumulativeProbability = 0.55;
      t.e4c5nf3.cumulativeProbability = 0.35;

      final extractor = LineExtractor(
        config: TreeBuildConfig(
          startFen: t.root.fen,
          playAsWhite: true,
          minProbability: 0.01,
        ),
      );
      final lines = extractor.extract(t.toTree());
      expect(lines.length, 2);

      // Both lines play e4 then Nf3 — one representative survives, and it
      // is the more likely branch (1...e5).
      final kept = LinePruner.prune(lines, targetCount: 10);
      expect(kept.length, 1);
      expect(kept.single.movesSan[1], 'e5');
    });

    test('preserves input order among survivors', () {
      final lines = [
        _line('first', 0.2, [('a', 0.1)]),
        _line('second', 0.9, [('b', 5.0)]),
        _line('third', 0.5, [('c', 1.0)]),
      ];
      // Selection order is second, third, first — output keeps input order.
      final kept = LinePruner.prune(lines, targetCount: 3);
      expect(kept.map(_name), ['first', 'second', 'third']);
    });
  });
}
