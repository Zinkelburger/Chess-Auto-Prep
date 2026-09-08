import 'package:chess_auto_prep/features/holes/services/hole_scoring.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:flutter_test/flutter_test.dart';

const whiteToMoveFen =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
const blackToMoveFen =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

TrickTarget target({String fen = whiteToMoveFen, double reach = 0.5}) =>
    TrickTarget(
      node: OpeningTreeNode(move: '', fen: fen),
      movePath: const [],
      reach: reach,
    );

void main() {
  group('TrickCandidateMetrics sign conventions', () {
    test('White attacker: straight through, no flip', () {
      final m = TrickCandidateMetrics.fromWhiteCp(
        candidateWhiteCp: 10,
        bestWhiteCp: 50,
        attackerIsWhite: true,
      );
      expect(m.candidateRawCp, 10);
      expect(m.bestRawCp, 50);
      expect(m.objectiveCostCp, 40);
      expect(m.practicalGapCp(120), 110);
      expect(m.netGainCp(120), 70);
    });

    test('Black attacker: White-normalized evals flip', () {
      // Engine says -80 (White-normalized) for the best line, -30 for the
      // candidate: from Black's side that is best +80, candidate +30.
      final m = TrickCandidateMetrics.fromWhiteCp(
        candidateWhiteCp: -30,
        bestWhiteCp: -80,
        attackerIsWhite: false,
      );
      expect(m.candidateRawCp, 30);
      expect(m.bestRawCp, 80);
      expect(m.objectiveCostCp, 50);
      // Probe expected is already attacker-perspective — no flip.
      expect(m.practicalGapCp(120), 90);
      expect(m.netGainCp(120), 40);
    });

    test('Black attacker: unflipped code would pass the window', () {
      // Best for Black is -100 (White-normalized), candidate -30: the real
      // cost is 70cp. Naive White-side subtraction gives -100-(-30) = -70,
      // which would sneak inside any window.
      final m = TrickCandidateMetrics.fromWhiteCp(
        candidateWhiteCp: -30,
        bestWhiteCp: -100,
        attackerIsWhite: false,
      );
      expect(m.objectiveCostCp, 70);
    });
  });

  group('selectCandidates', () {
    const lines = [
      DiscoveredCandidate(uci: 'g1f3', san: 'Nf3', whiteCp: 50),
      DiscoveredCandidate(uci: 'b1c3', san: 'Nc3', whiteCp: 30),
      DiscoveredCandidate(uci: 'b2b4', san: 'b4', whiteCp: -10),
      DiscoveredCandidate(uci: 'g2g4', san: 'g4', whiteCp: -60),
    ];

    test('window filter includes the edge and marks novelties', () {
      final t = target();
      final candidates = selectCandidates(
        target: t,
        lines: lines,
        inTreeSans: {'Nf3'},
        attackerIsWhite: true,
        windowCp: 60,
        maxPerNode: 4,
      );
      // g4 costs 110 > 60 and is dropped; b4 costs exactly 60 and stays.
      expect(candidates.map((c) => c.san), ['Nf3', 'Nc3', 'b4']);
      expect(candidates.map((c) => c.isNovelty), [false, true, true]);
      expect(candidates.every((c) => c.bestSan == 'Nf3'), isTrue);
    });

    test('per-node cap keeps engine order but never drops in-tree moves', () {
      final t = target();
      final candidates = selectCandidates(
        target: t,
        lines: lines,
        inTreeSans: {'b4'},
        attackerIsWhite: true,
        windowCp: 60,
        maxPerNode: 2,
      );
      // Cap of 2 takes Nf3 + Nc3; b4 survives past the cap because the
      // source tree plays it.
      expect(candidates.map((c) => c.san), ['Nf3', 'Nc3', 'b4']);
      expect(candidates.last.isNovelty, isFalse);
    });

    test('Black attacker window uses flipped costs', () {
      const blackLines = [
        DiscoveredCandidate(uci: 'g8f6', san: 'Nf6', whiteCp: -100),
        DiscoveredCandidate(uci: 'e7e5', san: 'e5', whiteCp: -30),
      ];
      final t = target(fen: blackToMoveFen);
      final candidates = selectCandidates(
        target: t,
        lines: blackLines,
        inTreeSans: const {},
        attackerIsWhite: false,
        windowCp: 60,
        maxPerNode: 4,
      );
      // e5 costs 70cp for Black — outside the window despite naive
      // White-side arithmetic saying -70.
      expect(candidates.map((c) => c.san), ['Nf6']);
    });

    test('no lines or no room yields nothing', () {
      expect(
        selectCandidates(
          target: target(),
          lines: const [],
          inTreeSans: const {},
          attackerIsWhite: true,
          windowCp: 60,
          maxPerNode: 3,
        ),
        isEmpty,
      );
      expect(
        selectCandidates(
          target: target(),
          lines: lines,
          inTreeSans: const {},
          attackerIsWhite: true,
          windowCp: 60,
          maxPerNode: 0,
        ),
        isEmpty,
      );
    });
  });

  group('prescreen + probe selection', () {
    TrickCandidate candidate({
      required double reach,
      required int costCp,
      String san = 'x',
    }) => TrickCandidate(
      target: target(reach: reach),
      san: san,
      uci: 'a1a2',
      bestSan: 'best',
      metrics: TrickCandidateMetrics(candidateRawCp: -costCp, bestRawCp: 0),
      isNovelty: true,
    );

    test('reach dominates, cost discounts linearly at half weight', () {
      final free = candidate(reach: 0.4, costCp: 0);
      final pricey = candidate(reach: 0.4, costCp: 60);
      expect(prescreenScore(free, windowCp: 60), closeTo(0.4, 1e-9));
      expect(prescreenScore(pricey, windowCp: 60), closeTo(0.2, 1e-9));
    });

    test('selectProbeCandidates ranks by prescreen score, stable', () {
      final a = candidate(reach: 0.10, costCp: 0, san: 'a');
      final b = candidate(reach: 0.30, costCp: 60, san: 'b'); // 0.15
      final c = candidate(reach: 0.12, costCp: 0, san: 'c');
      final picked = selectProbeCandidates([a, b, c], budget: 2, windowCp: 60);
      expect(picked.map((x) => x.san), ['b', 'c']);
    });

    test('a zero window scores on reach alone, never NaN', () {
      // With no window there is nothing to discount against: dividing the
      // cost by it would produce 0/0, and one NaN poisons the whole sort.
      final score = prescreenScore(
        candidate(reach: 0.4, costCp: 25),
        windowCp: 0,
      );
      expect(score.isNaN, isFalse);
      expect(score, closeTo(0.4, 1e-9));
    });

    test('a budget of one still probes the best candidate', () {
      final a = candidate(reach: 0.10, costCp: 0, san: 'a');
      final b = candidate(reach: 0.30, costCp: 60, san: 'b'); // 0.15
      final picked = selectProbeCandidates([a, b], budget: 1, windowCp: 60);
      expect(picked.map((x) => x.san), ['b']);
    });

    test('no budget probes nothing', () {
      final a = candidate(reach: 0.10, costCp: 0, san: 'a');
      expect(selectProbeCandidates([a], budget: 0, windowCp: 60), isEmpty);
    });
  });
}
