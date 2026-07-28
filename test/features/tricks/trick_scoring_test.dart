import 'package:chess_auto_prep/features/tricks/services/trick_scoring.dart';
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
    test('White trickster: straight through, no flip', () {
      final m = TrickCandidateMetrics.fromWhiteCp(
        candidateWhiteCp: 10,
        bestWhiteCp: 50,
        tricksterIsWhite: true,
      );
      expect(m.candidateRawCp, 10);
      expect(m.bestRawCp, 50);
      expect(m.objectiveCostCp, 40);
      expect(m.practicalGapCp(120), 110);
      expect(m.netGainCp(120), 70);
    });

    test('Black trickster: White-normalized evals flip', () {
      // Engine says -80 (White-normalized) for the best line, -30 for the
      // candidate: from Black's side that is best +80, candidate +30.
      final m = TrickCandidateMetrics.fromWhiteCp(
        candidateWhiteCp: -30,
        bestWhiteCp: -80,
        tricksterIsWhite: false,
      );
      expect(m.candidateRawCp, 30);
      expect(m.bestRawCp, 80);
      expect(m.objectiveCostCp, 50);
      // Probe expected is already trickster-perspective — no flip.
      expect(m.practicalGapCp(120), 90);
      expect(m.netGainCp(120), 40);
    });

    test('Black trickster: unflipped code would pass the window', () {
      // Best for Black is -100 (White-normalized), candidate -30: the real
      // cost is 70cp. Naive White-side subtraction gives -100-(-30) = -70,
      // which would sneak inside any window.
      final m = TrickCandidateMetrics.fromWhiteCp(
        candidateWhiteCp: -30,
        bestWhiteCp: -100,
        tricksterIsWhite: false,
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
        tricksterIsWhite: true,
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
        tricksterIsWhite: true,
        windowCp: 60,
        maxPerNode: 2,
      );
      // Cap of 2 takes Nf3 + Nc3; b4 survives past the cap because the
      // source tree plays it.
      expect(candidates.map((c) => c.san), ['Nf3', 'Nc3', 'b4']);
      expect(candidates.last.isNovelty, isFalse);
    });

    test('Black trickster window uses flipped costs', () {
      const blackLines = [
        DiscoveredCandidate(uci: 'g8f6', san: 'Nf6', whiteCp: -100),
        DiscoveredCandidate(uci: 'e7e5', san: 'e5', whiteCp: -30),
      ];
      final t = target(fen: blackToMoveFen);
      final candidates = selectCandidates(
        target: t,
        lines: blackLines,
        inTreeSans: const {},
        tricksterIsWhite: false,
        windowCp: 60,
        maxPerNode: 4,
      );
      // e5 costs 70cp for Black — outside the window despite naive
      // White-side arithmetic saying -70.
      expect(candidates.map((c) => c.san), ['Nf6']);
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
  });

  group('dedupTargets', () {
    test('sums reach across move-counter variants and clamps at 1.0', () {
      // Same position, different halfmove/fullmove counters.
      const fenA = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      const fenB = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 3 9';
      final first = TrickTarget(
        node: OpeningTreeNode(move: '', fen: fenA),
        movePath: const ['e4'],
        reach: 0.7,
      );
      final dupe = TrickTarget(
        node: OpeningTreeNode(move: '', fen: fenB),
        movePath: const ['d4', 'transpose'],
        reach: 0.6,
      );
      final other = TrickTarget(
        node: OpeningTreeNode(move: '', fen: whiteToMoveFen),
        movePath: const [],
        reach: 0.2,
      );

      final deduped = dedupTargets([first, dupe, other]);
      expect(deduped.length, 2);
      expect(deduped.first.reach, closeTo(1.0, 1e-9)); // 0.7+0.6 clamped
      expect(deduped.first.movePath, ['e4']); // first-seen representative
      expect(deduped.last.reach, closeTo(0.2, 1e-9));
    });
  });

  group('selectDiscoveryTargets', () {
    test('applies reach floor then top-N by reach', () {
      final targets = [
        target(reach: 0.004), // below floor
        target(reach: 0.30),
        target(reach: 0.10),
        target(reach: 0.20),
      ];
      final picked = selectDiscoveryTargets(
        targets,
        minReachProb: 0.005,
        maxNodes: 2,
      );
      expect(picked.map((t) => t.reach), [0.30, 0.20]);
    });
  });
}
