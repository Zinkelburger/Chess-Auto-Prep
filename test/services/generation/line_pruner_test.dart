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

/// Line with a real move order, optionally cut at a transposition into
/// [transposesInto]'s move order.
ExtractedLine _lineAt(
  List<String> movesSan,
  double probability,
  List<(String, double)> units, {
  List<String>? transposesInto,
}) {
  return ExtractedLine(
    movesSan: movesSan,
    movesUci: movesSan,
    probability: probability,
    coverageUnits: [
      for (final (key, value) in units)
        LineCoverageUnit(key: key, value: value),
    ],
    transposesInto: transposesInto,
  );
}

String _name(ExtractedLine l) => l.movesSan.single;

void main() {
  group('LinePruner', () {
    test('a kept transposition stub pins the line it points at', () {
      // 'stub' transposes into the position 'owner' continues from. The
      // greedy scores them independently, and a 50% coverage target keeps
      // only the stub — which would name a move order the book no longer
      // contains, and drop the shared continuation entirely.
      final owner = _lineAt(['d4', 'Nf6', 'c4', 'e6'], 0.10, [('shared', 1.0)]);
      final stub = _lineAt(
        ['c4', 'e6', 'd4', 'Nf6'],
        0.90,
        [('stub-only', 9.0)],
        transposesInto: ['d4', 'Nf6', 'c4', 'e6'],
      );

      final kept = LinePruner.prune([owner, stub], coverageTarget: 0.5);
      final orders = kept.map((l) => l.movesSan.join(' ')).toList();

      expect(orders, contains('c4 e6 d4 Nf6'));
      expect(
        orders,
        contains('d4 Nf6 c4 e6'),
        reason: 'the owner must come back with the stub that names it',
      );
    });

    test('pinning an owner outranks the targetCount cap', () {
      final owner = _lineAt(['d4', 'Nf6'], 0.10, [('shared', 1.0)]);
      final stub = _lineAt(
        ['Nf3', 'Nf6', 'd4'],
        0.90,
        [('stub-only', 9.0)],
        transposesInto: ['d4', 'Nf6'],
      );

      // A cap of 1 would keep the stub alone; a dangling pointer is the
      // worse book, so the owner is pinned back in over the cap.
      final kept = LinePruner.prune([owner, stub], targetCount: 1);
      expect(kept, hasLength(2));
    });

    test('a stub whose owner is already kept pins nothing extra', () {
      final owner = _lineAt(['d4', 'Nf6', 'c4'], 0.50, [('shared', 5.0)]);
      final stub = _lineAt(
        ['c4', 'Nf6', 'd4'],
        0.50,
        [('stub-only', 5.0)],
        transposesInto: ['d4', 'Nf6'],
      );
      final other = _lineAt(['e4', 'e5'], 0.10, [('unrelated', 1.0)]);

      final kept = LinePruner.prune([owner, stub, other], coverageTarget: 1.0);
      expect(kept, hasLength(3));
    });

    test('targetCount <= 0 means no cap, not no pruning', () {
      // The old contract returned the input untouched here, which handed
      // callers back every exact duplicate. Pruning always runs now; 0 only
      // says "do not cap the count".
      final lines = [
        _line('a', 0.5, [('e2e4', 1.0)]),
        _line('b', 0.5, [('e2e4', 1.0)]),
      ];
      expect(LinePruner.prune(lines, targetCount: 0).map(_name), ['a']);
      expect(LinePruner.prune(lines, targetCount: -1).map(_name), ['a']);
    });

    test('coverageTarget stops early once the share is reached', () {
      // Coverage is measured in reach mass even though the greedy *orders*
      // picks by unit value: 'likely' is 90% of the games reaching this set,
      // so it alone satisfies a 90% target.
      final lines = [
        _line('likely', 0.9, [('a', 9.0)]),
        _line('rare', 0.1, [('b', 1.0)]),
      ];
      expect(LinePruner.prune(lines, coverageTarget: 0.9).map(_name), [
        'likely',
      ]);
      expect(LinePruner.prune(lines, coverageTarget: 1.0).map(_name), [
        'likely',
        'rare',
      ]);
    });

    test('a hard cap still wins over an unmet coverage target', () {
      final lines = [
        _line('a', 0.5, [('a', 1.0)]),
        _line('b', 0.5, [('b', 1.0)]),
        _line('c', 0.5, [('c', 1.0)]),
      ];
      final kept = LinePruner.prune(lines, targetCount: 2, coverageTarget: 1.0);
      expect(kept.length, 2);
    });

    test('never returns nothing when there is something to teach', () {
      final lines = [
        _line('a', 0.5, [('a', 1.0)]),
        _line('b', 0.5, [('b', 1.0)]),
      ];
      expect(LinePruner.prune(lines, coverageTarget: 0.0).length, 1);
    });

    test('lines teaching identical decisions collapse to one', () {
      // Same keys = the same positions answered the same way.
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

    test('keeps both answers when the opponent branches', () {
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

      // Both lines play e4 then Nf3, so the old projection key called them
      // duplicates and dropped the 1...c5 one — leaving a repertoire with no
      // answer to 1...c5 at all. They are two positions and two things to
      // know, so both survive.
      final kept = LinePruner.prune(lines);
      expect(kept.length, 2);
      expect(kept.map((l) => l.movesSan[1]), ['e5', 'c5']);
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
