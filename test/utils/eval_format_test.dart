import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';

/// Pins the packed-eval encoding and its single display path.
///
/// Before this suite existed, [kMateCpThreshold] equalled [kMateCpBase] while
/// [mateToCp] packed mate-in-N as `kMateCpBase - N`. Every packed mate
/// therefore landed *below* the threshold, [isMateEval] returned false for all
/// of them, and the mate branch at six separate display sites was dead code —
/// a forced mate rendered as `+100.0`. These tests fail if that skew returns.
void main() {
  group('mate packing round-trips', () {
    test('every realistic mate distance survives cp encoding', () {
      for (final mate in [1, 2, 3, 5, 12, 40, 99, kMaxMateDistance]) {
        final cp = mateToCp(mate);
        expect(
          isMateEval(cp),
          isTrue,
          reason: 'mate-in-$mate packed as $cp must read as a mate',
        );
        expect(cpToMate(cp), mate, reason: 'mate-in-$mate must round-trip');
      }
    });

    test('negative mates round-trip with their sign', () {
      for (final mate in [-1, -3, -20, -99]) {
        final cp = mateToCp(mate);
        expect(isMateEval(cp), isTrue);
        expect(cpToMate(cp), mate);
      }
    });

    test('ordinary evals are never mistaken for mates', () {
      for (final cp in [0, 35, -35, 250, -250, 1500, -1500, 8999, -8999]) {
        expect(
          isMateEval(cp),
          isFalse,
          reason: '$cp is a normal evaluation, not a mate',
        );
        expect(cpToMate(cp), isNull);
      }
    });

    test('saturation sentinels read as mate with unknown distance', () {
      expect(cpToMate(kBestEvalCp), 0);
      expect(cpToMate(kWorstEvalCp), 0);
    });
  });

  group('formatPackedEval', () {
    test('renders forced mates as #N, not as a large centipawn score', () {
      expect(formatPackedEval(mateToCp(3)), '#3');
      expect(formatPackedEval(mateToCp(1)), '#1');
      expect(formatPackedEval(mateToCp(-3)), '-#3');
    });

    test('renders ordinary evals with a sign and one decimal by default', () {
      expect(formatPackedEval(0), '+0.0');
      expect(formatPackedEval(130), '+1.3');
      expect(formatPackedEval(-50), '-0.5');
    });

    test('honours the decimals argument for high-precision panes', () {
      expect(formatPackedEval(135, decimals: 2), '+1.35');
      expect(formatPackedEval(-135, decimals: 2), '-1.35');
    });

    test('unknown-distance mates render as a bare #', () {
      expect(formatPackedEval(kBestEvalCp), '#');
      expect(formatPackedEval(kWorstEvalCp), '#');
    });
  });

  group('formatEvalDisplay agrees with formatPackedEval', () {
    test('same mate reads identically through both entry points', () {
      for (final mate in [1, 3, 20, -1, -3, -20]) {
        expect(
          formatEvalDisplay(scoreMate: mate),
          formatPackedEval(mateToCp(mate)),
          reason: 'mate-in-$mate must look the same in every pane',
        );
      }
    });

    test(
      'same centipawn score reads identically through both entry points',
      () {
        for (final cp in [0, 130, -50, 900]) {
          expect(formatEvalDisplay(scoreCp: cp), formatPackedEval(cp));
        }
      },
    );

    test('null scores render as a placeholder', () {
      expect(formatEvalDisplay(), '--');
    });
  });
}
