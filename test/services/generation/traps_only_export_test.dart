import 'package:chess_auto_prep/models/trap_line_info.dart';
import 'package:chess_auto_prep/services/generation/trap_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stand-in for an extracted line: the filter only reads the moves.
class _Line {
  const _Line(this.movesSan);
  final List<String> movesSan;
}

TrapLineInfo _trap(List<String> movesSan) => TrapLineInfo(
  movesSan: movesSan,
  trapScore: 0.2,
  popularProb: 0.3,
  popularMove: 'Nxe5',
  bestMove: 'Nf6',
  popularEvalCp: -200,
  bestEvalCp: 10,
  evalDiffCp: 210,
  cumulativeProb: 0.05,
  trickSurplus: 0.02,
  expectimaxValue: 0.55,
  wpEval: 0.52,
);

void main() {
  group('keepLinesThroughTraps', () {
    List<String> movesOf(_Line l) => l.movesSan;

    test('keeps lines whose prefix is a trap position', () {
      final lines = [
        const _Line(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nd4', 'Nxe5']),
        const _Line(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']),
      ];
      final kept = keepLinesThroughTraps(lines, [
        _trap(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Nd4']),
      ], movesOf);

      expect(kept, hasLength(1));
      expect(kept.single.movesSan.last, 'Nxe5');
    });

    test('matches on move boundaries, not raw substrings', () {
      // "Nf3" must not match a line that plays "Nf3+" — joining with spaces
      // and comparing whole prefixes is what prevents that.
      final lines = [
        const _Line(['e4', 'e5', 'Nf3+']),
      ];
      expect(
        keepLinesThroughTraps(lines, [
          _trap(['e4', 'e5', 'Nf3']),
        ], movesOf),
        isEmpty,
      );
    });

    test('a trap at the exact end of a line still counts', () {
      final lines = [
        const _Line(['d4', 'd5', 'Bf4']),
      ];
      expect(
        keepLinesThroughTraps(lines, [
          _trap(['d4', 'd5', 'Bf4']),
        ], movesOf),
        hasLength(1),
      );
    });

    test('no traps means nothing exported, not everything', () {
      final lines = [
        const _Line(['e4', 'e5']),
      ];
      expect(keepLinesThroughTraps(lines, const [], movesOf), isEmpty);
    });

    test('a deeper line still matches a shallow trap', () {
      final lines = [
        const _Line(['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6']),
      ];
      expect(
        keepLinesThroughTraps(lines, [
          _trap(['e4', 'c5', 'Nf3']),
        ], movesOf),
        hasLength(1),
      );
    });
  });
}
