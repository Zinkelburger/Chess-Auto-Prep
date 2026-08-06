/// The pass that answers "so how is that punished?" for lines the build ends
/// because the opponent's move left us winning.
///
/// Two things matter and are pinned here: which positions get probed (the
/// wrong set means either a wasted engine pass or missing variations), and
/// that everything about the pass is best-effort — a missing engine or a bad
/// PV must cost the variation, never the export.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/course/refutation_prober.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_fakes.dart';

const _config = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  verifyDepth: 20,
);

/// FEN after [sans] from the standard start.
String fenAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos.fen;
}

ExtractedLine line(
  List<String> sans, {
  PruneReason prune = PruneReason.evalTooHigh,
  String? leafFen,
  List<LineChoice> choices = const [],
}) => ExtractedLine(
  movesSan: sans,
  movesUci: const [],
  probability: 0.1,
  leafPruneReason: prune,
  leafFen: leafFen ?? fenAfter(sans),
  choices: choices,
);

/// A position an exported line passes through.  [best] is the eval available
/// to the side to move, from our perspective.
LineChoice choice(
  String fen, {
  required bool ours,
  int? best = 30,
  List<String> known = const [],
  int index = 0,
}) => LineChoice(
  moveIndex: index,
  fenBefore: fen,
  isOurMove: ours,
  bestEvalCpForUs: best,
  knownUcis: known,
);

/// A game database that has seen [uci] played [count] times at [fen].
PgnFreqMap freqMapWith(String fen, Map<String, int> countByUci) {
  final map = PgnFreqMap();
  final key = canonicalizeFen4(fen);
  countByUci.forEach((uci, count) {
    for (var i = 0; i < count; i++) {
      map.recordMove(key, uci, '');
    }
  });
  return map;
}

void main() {
  group('targets', () {
    test('takes eval-pruned leaves where it is our turn to punish', () {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(),
      );
      // Black's 3... Nxe4 leaves White to move.
      final punishable = line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);

      expect(prober.targets([punishable]), [punishable.leafFen]);
    });

    test('skips leaves that end on our own move', () {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(),
      );
      // We are the ones who just played well; nothing to punish.
      expect(
        prober.targets([
          line(['e4', 'e5', 'Nf3']),
        ]),
        isEmpty,
      );
    });

    test('skips leaves the build ended for any other reason', () {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(),
      );
      final ranOutOfDepth = line([
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ], prune: PruneReason.none);

      expect(prober.targets([ranOutOfDepth]), isEmpty);
    });

    test('probes a repeated position once', () {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(),
      );
      final fen = fenAfter(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);

      expect(
        prober.targets([
          line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4'], leafFen: fen),
          line(['e4', 'Nf6', 'Nc3', 'e5', 'Bc4', 'Nxe4'], leafFen: fen),
        ]),
        [fen],
      );
    });
  });

  group('probe', () {
    late FakeStockfishPool pool;

    setUp(() => pool = FakeStockfishPool());

    test('returns the punishment as SAN from the losing position', () async {
      final blunder = line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);
      pool.discoveryByFen[blunder.leafFen!] = DiscoveryResult(
        lines: [
          discoveryLine(
            pvNumber: 1,
            cpWhite: 320,
            pv: ['c4f7', 'e8e7', 'c3e4'],
          ),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probe([blunder]);

      expect(out[blunder.leafFen], ['Bxf7+', 'Ke7', 'Nxe4']);
    });

    test('shows a few moves, not the whole principal variation', () async {
      final blunder = line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);
      pool.discoveryByFen[blunder.leafFen!] = DiscoveryResult(
        lines: [
          discoveryLine(
            pvNumber: 1,
            cpWhite: 320,
            pv: [
              'c3e4',
              'd7d5',
              'c4d5',
              'd8d5',
              'd2d3',
              'b8c6',
              'g1f3',
              'c8g4',
            ],
          ),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probe([blunder]);

      expect(out[blunder.leafFen], hasLength(RefutationProber.plies));
    });

    test('a PV that stops replaying keeps the prefix that did', () async {
      final blunder = line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);
      pool.discoveryByFen[blunder.leafFen!] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 320, pv: ['c4f7', 'a1a8']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probe([blunder]);

      expect(out[blunder.leafFen], ['Bxf7+']);
    });

    test('a failed search drops that position and nothing else', () async {
      final scripted = line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);
      // Unscripted in the fake pool: discoverMoves throws for this one.
      final unscripted = line(['d4', 'd5', 'Nc3', 'Nf6', 'Bf4', 'Nh5']);
      pool.discoveryByFen[scripted.leafFen!] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 320, pv: ['c4f7']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probe([unscripted, scripted]);

      expect(out.keys, [scripted.leafFen]);
    });

    test('no engine means no variations, not a failure', () async {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(workers: 0),
      );

      expect(
        await prober.probe([
          line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']),
        ]),
        isEmpty,
      );
    });

    test('stops when the run is cancelled', () async {
      final blunder = line(['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4']);
      pool.discoveryByFen[blunder.leafFen!] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 320, pv: ['c4f7']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probe([blunder], isCancelled: () => true);

      expect(out, isEmpty);
    });
  });

  group('alternativeSites', () {
    test('are the positions the export passes through, deduplicated', () {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(),
      );
      final shared = choice(kStandardStartFen, ours: true);
      final own = choice(fenAfter(['e4']), ours: false, index: 1);

      final sites = prober.alternativeSites([
        line(['e4', 'e5'], choices: [shared, own]),
        line(['e4', 'c5'], choices: [shared, own]),
      ]);

      expect(sites.map((s) => s.fenBefore), [
        kStandardStartFen,
        fenAfter(['e4']),
      ]);
    });

    test('skip a position with nothing to compare an alternative against', () {
      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(),
      );

      expect(
        prober.alternativeSites([
          line(
            ['e4'],
            choices: [choice(kStandardStartFen, ours: true, best: null)],
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('probeAlternatives', () {
    late FakeStockfishPool pool;

    setUp(() => pool = FakeStockfishPool());
    tearDown(() => MaiaFactory.testOverride = null);

    /// Maia plays [uci] at [fen] with probability [probability].
    void maiaPlays(String fen, String uci, double probability) {
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        fen: {uci: probability},
      });
    }

    test('shows what the natural move we skip runs into', () async {
      // 1. f3 is a move humans play and the engine hates.
      maiaPlays(kStandardStartFen, 'f2f3', 0.30);
      pool.discoveryByFen[fenAfter(['f3'])] = DiscoveryResult(
        lines: [
          discoveryLine(
            pvNumber: 1,
            cpWhite: -400,
            pv: ['e7e5', 'g2g4', 'd8h4'],
          ),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
      ]);

      final found = out[kStandardStartFen]!;
      expect(found.san, 'f3');
      expect(found.continuation, ['e5', 'g4', 'Qh4#']);
      // 30 for us before, -400 after: a blunder, not an inaccuracy.
      expect(found.lossCp, 430);
      expect(found.sanWithNag, 'f3?');
    });

    test('shows what the try they should avoid runs into', () async {
      // Their best in the tree leaves us +35; 1... f5 leaves us +300.
      final afterE4 = fenAfter(['e4']);
      maiaPlays(afterE4, 'f7f5', 0.20);
      pool.discoveryByFen[fenAfter(['e4', 'f5'])] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 300, pv: ['e4f5']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(['e4', 'e5'], choices: [choice(afterE4, ours: false, best: 35)]),
      ]);

      final found = out[afterE4]!;
      expect(found.san, 'f5');
      expect(found.continuation, ['exf5']);
      expect(found.lossCp, 265);
      expect(found.sanWithNag, 'f5?!', reason: 'a mistake, not a blunder');
    });

    test('says nothing about a move that is simply playable', () async {
      maiaPlays(kStandardStartFen, 'g1f3', 0.40);
      pool.discoveryByFen[fenAfter(['Nf3'])] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 20, pv: ['d7d5']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
      ]);

      expect(out, isEmpty);
    });

    test('skips moves the tree already holds', () async {
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        kStandardStartFen: {'e2e4': 0.50, 'f2f3': 0.30},
      });
      pool.discoveryByFen[fenAfter(['f3'])] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: -400, pv: ['e7e5']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(
          ['e4'],
          choices: [
            choice(kStandardStartFen, ours: true, known: ['e2e4']),
          ],
        ),
      ]);

      // e2e4 is the book move: it is not probed, and f2f3 still is.
      expect(out[kStandardStartFen]?.san, 'f3');
      expect(pool.discoverMultiPvCalls, hasLength(1));
    });

    test('ignores a move too rare for anyone to wonder about', () async {
      maiaPlays(kStandardStartFen, 'a2a3', 0.01);

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
      ]);

      expect(out, isEmpty);
      expect(pool.discoverMultiPvCalls, isEmpty);
    });

    test('falls back to the game database when Maia is unavailable', () async {
      pool.discoveryByFen[fenAfter(['f3'])] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: -400, pv: ['e7e5']),
        ],
      );

      final prober = RefutationProber(
        config: _config,
        pool: pool,
        freqMap: freqMapWith(kStandardStartFen, {'f2f3': 3, 'e2e4': 7}),
      );
      final out = await prober.probeAlternatives([
        line(
          ['e4'],
          choices: [
            choice(kStandardStartFen, ours: true, known: ['e2e4']),
          ],
        ),
      ]);

      expect(out[kStandardStartFen]?.san, 'f3');
    });

    test('no move source means no variations, not a failure', () async {
      final prober = RefutationProber(config: _config, pool: pool);

      expect(
        await prober.probeAlternatives([
          line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
        ]),
        isEmpty,
      );
      expect(pool.discoverMultiPvCalls, isEmpty);
    });

    test('a refutation with no continuation is not shown', () async {
      maiaPlays(kStandardStartFen, 'f2f3', 0.30);
      // A PV that will not replay from this position.
      pool.discoveryByFen[fenAfter(['f3'])] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: -400, pv: ['a1a8']),
        ],
      );

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
      ]);

      expect(out, isEmpty);
    });

    test('stops when the run is cancelled', () async {
      maiaPlays(kStandardStartFen, 'f2f3', 0.30);

      final prober = RefutationProber(config: _config, pool: pool);
      final out = await prober.probeAlternatives([
        line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
      ], isCancelled: () => true);

      expect(out, isEmpty);
      expect(pool.discoverMultiPvCalls, isEmpty);
    });

    test('no engine means no variations', () async {
      maiaPlays(kStandardStartFen, 'f2f3', 0.30);

      final prober = RefutationProber(
        config: _config,
        pool: FakeStockfishPool(workers: 0),
      );

      expect(
        await prober.probeAlternatives([
          line(['e4'], choices: [choice(kStandardStartFen, ours: true)]),
        ]),
        isEmpty,
      );
    });
  });
}
