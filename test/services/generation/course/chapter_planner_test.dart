import 'package:chess_auto_prep/services/generation/course/chapter_planner.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedLine _line(String moves, {double probability = 0.01}) {
  final san = moves.split(' ').where((m) => m.isNotEmpty).toList();
  return ExtractedLine(movesSan: san, movesUci: san, probability: probability);
}

/// `count` lines sharing [prefix] and diverging on a synthetic final move.
List<ExtractedLine> _fan(
  String prefix,
  int count, {
  double probability = 0.01,
}) {
  const fillers = [
    'a3',
    'a4',
    'b3',
    'b4',
    'c3',
    'c4',
    'd3',
    'g3',
    'g4',
    'h3',
    'h4',
    'Na3',
    'Nc3',
    'Nf3',
    'Nh3',
    'Be2',
    'Be3',
    'Bd3',
    'Bf4',
    'Bg5',
    'Qd2',
    'Qe2',
    'Rb1',
    'Kd2',
    'Kf1',
  ];
  return [
    for (var i = 0; i < count; i++)
      _line(
        '$prefix ${fillers[i % fillers.length]}$i',
        probability: probability,
      ),
  ];
}

void main() {
  group('ChapterPlanner cut by ECO code', _ecoTests);

  group('ChapterPlanner', () {
    const planner = ChapterPlanner(maxLines: 10, minLines: 3);

    test('keeps a small repertoire as one chapter', () {
      final groups = planner.plan(_fan('e4 e5', 5));

      expect(groups, hasLength(1));
      expect(groups.single.prefixSan, ['e4', 'e5']);
      expect(groups.single.isMisc, isFalse);
    });

    test('splits at the branch point when a group is too big', () {
      final groups = planner.plan([
        ..._fan('e4 e5 Nf3', 8),
        ..._fan('e4 c5 Nf3', 8),
      ]);

      expect(groups, hasLength(2));
      expect(groups.map((g) => g.prefixSan[1]).toSet(), {
        'e5',
        'c5',
      }, reason: 'chapters divide at the opponent move that splits the mass');
    });

    test('orders chapters by how often they are reached', () {
      final groups = planner.plan([
        ..._fan('e4 c5 Nf3', 8, probability: 0.01),
        ..._fan('e4 e5 Nf3', 8, probability: 0.05),
      ]);

      expect(groups.first.prefixSan[1], 'e5');
      expect(groups.first.weight, greaterThan(groups.last.weight));
    });

    test('sweeps undersized branches into one misc chapter, ordered last', () {
      final groups = planner.plan([
        ..._fan('e4 e5 Nf3', 8),
        ..._fan('e4 c5 Nf3', 8),
        // Two lines each: far too small to deserve their own chapters.
        ..._fan('e4 d5 exd5', 2),
        ..._fan('e4 Nf6 e5', 2),
      ]);

      final misc = groups.where((g) => g.isMisc).toList();
      expect(misc, hasLength(1));
      expect(misc.single.lines, hasLength(4));
      expect(groups.last.isMisc, isTrue, reason: 'rarities come last');
    });

    test('keeps an oversized group whole when nothing clears the floor', () {
      // 12 lines, every one its own branch — splitting would yield 12 scraps.
      final groups = planner.plan(_fan('e4', 12));

      expect(groups, hasLength(1));
      expect(groups.single.lines, hasLength(12));
      expect(groups.single.isMisc, isFalse);
    });

    test('a line that ends at a branch point joins the misc bucket', () {
      final groups = planner.plan([
        ..._fan('e4 e5 Nf3', 8),
        ..._fan('e4 c5 Nf3', 8),
        _line('e4'),
      ]);

      final misc = groups.singleWhere((g) => g.isMisc);
      expect(misc.lines.single.movesSan, ['e4']);
    });

    test('every line survives the split exactly once', () {
      final lines = [
        ..._fan('e4 e5 Nf3', 8),
        ..._fan('e4 c5 Nf3', 8),
        ..._fan('e4 d5 exd5', 2),
      ];

      final planned = planner
          .plan(lines)
          .expand((g) => g.lines)
          .toList(growable: false);

      expect(planned, hasLength(lines.length));
      expect(planned.toSet(), hasLength(lines.length));
    });

    test('empty input yields no chapters', () {
      expect(planner.plan(const []), isEmpty);
    });
  });
}

// ── ECO-cut chapters ───────────────────────────────────────────────────────

/// Classify by the line's first move, standing in for the real ECO book.
OpeningLabel? Function(List<String>) _ecoByFirstMove(
  Map<String, OpeningLabel> byMove,
) =>
    (moves) => moves.isEmpty ? null : byMove[moves.first];

void _ecoTests() {
  const najdorf = OpeningLabel(
    eco: 'B90',
    name: 'Sicilian Defense: Najdorf Variation',
  );
  const ruy = OpeningLabel(eco: 'C60', name: 'Ruy Lopez');

  ChapterPlanner planner(Map<String, OpeningLabel> byMove) =>
      ChapterPlanner(maxLines: 40, minLines: 3, ecoOf: _ecoByFirstMove(byMove));

  test('lines are cut by code, not by where the tree branches', () {
    final lines = [..._fan('e4', 5), ..._fan('d4', 5)];
    final groups = planner({'e4': najdorf, 'd4': ruy}).plan(lines);

    expect(groups.length, 2);
    expect(groups.map((g) => g.ecoLabel?.eco).toSet(), {'B90', 'C60'});
    expect(groups.every((g) => g.lines.length == 5), isTrue);
  });

  test('one code reached by different move orders is still one chapter', () {
    // Two prefixes, one code: branch-point cutting would make two chapters.
    final lines = [..._fan('e4', 4), ..._fan('Nf3', 4)];
    final groups = planner({'e4': najdorf, 'Nf3': najdorf}).plan(lines);

    expect(groups.length, 1);
    expect(groups.single.lines.length, 8);
    expect(groups.single.ecoLabel?.eco, 'B90');
    // The chapter is named from the code, not from a prefix the lines do
    // not actually share.
    expect(groups.single.prefixSan, isEmpty);
  });

  test('a code too small to be a chapter joins the leftovers', () {
    final lines = [..._fan('e4', 6), ..._fan('d4', 2)];
    final groups = planner({'e4': najdorf, 'd4': ruy}).plan(lines);

    expect(groups.length, 2);
    expect(groups.first.ecoLabel?.eco, 'B90');
    expect(groups.last.isMisc, isTrue);
    expect(groups.last.lines.length, 2);
    expect(groups.last.ecoLabel, isNull);
  });

  test('unclassified lines land in the leftovers rather than vanishing', () {
    final lines = [..._fan('e4', 6), ..._fan('c4', 3)];
    final groups = planner({'e4': najdorf}).plan(lines);

    expect(groups.map((g) => g.lines.length).reduce((a, b) => a + b), 9);
    expect(groups.last.isMisc, isTrue);
  });

  test('an oversized code is still split at its branch points', () {
    final planner = ChapterPlanner(
      maxLines: 5,
      minLines: 2,
      ecoOf: _ecoByFirstMove({'e4': najdorf}),
    );
    final groups = planner.plan([..._fan('e4 c5', 5), ..._fan('e4 e5', 5)]);

    expect(groups.length, greaterThan(1));
    // Every sub-chapter still knows which code it belongs to.
    expect(groups.every((g) => g.ecoLabel?.eco == 'B90'), isTrue);
  });

  test('nothing classified falls back to branch-point cutting', () {
    final lines = [..._fan('e4', 5), ..._fan('d4', 5)];
    final groups = ChapterPlanner(
      maxLines: 5,
      minLines: 3,
      ecoOf: (_) => null,
    ).plan(lines);

    expect(groups.length, greaterThan(1));
    expect(groups.every((g) => g.ecoLabel == null), isTrue);
    // Not one giant misc bucket holding the whole book.
    expect(groups.where((g) => g.isMisc).length, lessThan(groups.length));
  });

  test('without a classifier the planner is unchanged', () {
    final lines = [..._fan('e4', 5), ..._fan('d4', 5)];
    final byBranch = ChapterPlanner(maxLines: 5, minLines: 3).plan(lines);
    expect(byBranch.every((g) => g.ecoLabel == null), isTrue);
  });
}
