import 'package:chess_auto_prep/services/generation/course/chapter_planner.dart';
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
      expect(
        groups.map((g) => g.prefixSan[1]).toSet(),
        {'e5', 'c5'},
        reason: 'chapters divide at the opponent move that splits the mass',
      );
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
