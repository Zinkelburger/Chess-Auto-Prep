import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';

TreeBuildConfig makeConfig({
  SearchAlgorithm searchAlgorithm = SearchAlgorithm.fast,
  int ourMultipv = 4,
  int maxEvalLossCp = 50,
  int oppMaxChildren = 4,
  int fastAltGapCp = 30,
  int openingWidthPlies = 3,
  SelectionMode selectionMode = SelectionMode.expectimax,
}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  searchAlgorithm: searchAlgorithm,
  ourMultipv: ourMultipv,
  maxEvalLossCp: maxEvalLossCp,
  oppMaxChildren: oppMaxChildren,
  fastAltGapCp: fastAltGapCp,
  openingWidthPlies: openingWidthPlies,
  selectionMode: selectionMode,
);

void main() {
  group('serialization', () {
    test('round-trips fast_alt_gap_cp', () {
      final json = makeConfig(fastAltGapCp: 45).toJson();
      final back = TreeBuildConfig.fromJson(json, startFen: kStandardStartFen);
      expect(back.fastAltGapCp, 45);
    });

    test('round-trips opening_width_plies', () {
      final json = makeConfig(openingWidthPlies: 6).toJson();
      final back = TreeBuildConfig.fromJson(json, startFen: kStandardStartFen);
      expect(back.openingWidthPlies, 6);
    });

    test('opening_width_plies defaults to 3 when absent', () {
      final back = TreeBuildConfig.fromJson({}, startFen: kStandardStartFen);
      expect(back.openingWidthPlies, 3);
    });

    test('round-trips search_algorithm', () {
      for (final algo in SearchAlgorithm.values) {
        final json = makeConfig(searchAlgorithm: algo).toJson();
        final back = TreeBuildConfig.fromJson(
          json,
          startFen: kStandardStartFen,
        );
        expect(back.searchAlgorithm, algo);
      }
    });

    test('legacy best_first maps onto the algorithm', () {
      final pure = TreeBuildConfig.fromJson({
        'best_first': false,
      }, startFen: kStandardStartFen);
      expect(pure.searchAlgorithm, SearchAlgorithm.pure);
      expect(pure.bestFirst, isFalse);

      final fast = TreeBuildConfig.fromJson({
        'best_first': true,
      }, startFen: kStandardStartFen);
      expect(fast.searchAlgorithm, SearchAlgorithm.fast);

      final unset = TreeBuildConfig.fromJson({}, startFen: kStandardStartFen);
      expect(unset.searchAlgorithm, SearchAlgorithm.fast);
    });

    test('still writes the legacy best_first key', () {
      expect(makeConfig().toJson()['best_first'], isTrue);
      expect(
        makeConfig(
          searchAlgorithm: SearchAlgorithm.pure,
        ).toJson()['best_first'],
        isFalse,
      );
    });
  });

  group('Pure Expectimax uses the configured values everywhere', () {
    test('no priority scaling', () {
      final c = makeConfig(searchAlgorithm: SearchAlgorithm.pure);
      for (final pri in [1.0, 0.01, 0.0001]) {
        expect(c.effectiveMultipv(pri), 4);
        expect(c.effectiveMaxEvalLossCp(pri), 50);
        expect(c.effectiveOppMaxChildren(pri), 4);
      }
    });
  });

  group('our-move alternative gating (expandAlternative)', () {
    test('Pure and trappy always expand', () {
      final pure = makeConfig(searchAlgorithm: SearchAlgorithm.pure);
      final trappy = makeConfig(selectionMode: SelectionMode.trappy);
      for (final c in [pure, trappy]) {
        expect(
          c.expandAlternative(gapCp: 400, altsAlreadyExpanded: 10),
          isTrue,
        );
      }
    });

    test('Fast gates by eval gap', () {
      final c = makeConfig();
      expect(c.expandAlternative(gapCp: 30, altsAlreadyExpanded: 0), isTrue);
      expect(c.expandAlternative(gapCp: 31, altsAlreadyExpanded: 0), isFalse);
      // Negative gap (alt outrates the incumbent judgment) always passes.
      expect(c.expandAlternative(gapCp: -10, altsAlreadyExpanded: 0), isTrue);
    });

    test('Fast caps expanded alternatives per node', () {
      final c = makeConfig();
      expect(
        c.expandAlternative(
          gapCp: 0,
          altsAlreadyExpanded: TreeBuildConfig.fastMaxExpandedAlts,
        ),
        isFalse,
      );
    });

    test('gap 0 disables the gate entirely', () {
      final c = makeConfig(fastAltGapCp: 0);
      expect(c.expandAlternative(gapCp: 400, altsAlreadyExpanded: 10), isTrue);
    });
  });

  group('Fast Expectimax priority zones', () {
    test('hot nodes get the full configured search', () {
      final c = makeConfig();
      expect(c.effectiveMultipv(1.0), 4);
      expect(c.effectiveMultipv(TreeBuildConfig.fastWarmPriority), 4);
      expect(c.effectiveMaxEvalLossCp(0.5), 50);
      expect(c.effectiveOppMaxChildren(0.5), 4);
    });

    test('warm nodes lose one MultiPV line only', () {
      final c = makeConfig();
      expect(c.effectiveMultipv(0.01), 3);
      expect(c.effectiveMaxEvalLossCp(0.01), 50);
      expect(c.effectiveOppMaxChildren(0.01), 4);
    });

    test('cold nodes get minimum MultiPV, halved window and fan-out', () {
      final c = makeConfig();
      expect(c.effectiveMultipv(0.0005), 2);
      expect(c.effectiveMaxEvalLossCp(0.0005), 25);
      expect(c.effectiveOppMaxChildren(0.0005), 2);
    });

    test('cold cap never exceeds the configured values', () {
      final c = makeConfig(ourMultipv: 2, oppMaxChildren: 2);
      expect(c.effectiveMultipv(0.0005), 2);
      expect(c.effectiveOppMaxChildren(0.0005), 2);
      // Unlimited opponent fan-out still gets a cold cap.
      final unlimited = makeConfig(oppMaxChildren: 0);
      expect(unlimited.effectiveOppMaxChildren(0.0005), 3);
      expect(unlimited.effectiveOppMaxChildren(0.5), 0);
    });
  });

  group('wide opening band (widensOpeningAtPly)', () {
    test('default band covers plies 0..3 (both colors first two moves)', () {
      final c = makeConfig(); // openingWidthPlies: 3
      expect(c.widensOpeningAtPly(0), isTrue); // white move 1
      expect(c.widensOpeningAtPly(1), isTrue); // black move 1
      expect(c.widensOpeningAtPly(2), isTrue); // white move 2
      expect(c.widensOpeningAtPly(3), isTrue); // black move 2
      expect(c.widensOpeningAtPly(4), isFalse); // white move 3 — narrowed
      expect(c.widensOpeningAtPly(20), isFalse);
    });

    test('0 disables the band entirely (including the root ply)', () {
      final c = makeConfig(openingWidthPlies: 0);
      expect(c.widensOpeningAtPly(0), isFalse);
      expect(c.widensOpeningAtPly(1), isFalse);
    });

    test('applies to Pure as well as Fast', () {
      final pure = makeConfig(searchAlgorithm: SearchAlgorithm.pure);
      expect(pure.widensOpeningAtPly(3), isTrue);
      expect(pure.widensOpeningAtPly(99), isFalse);
    });
  });
}
