import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/services/generation/engine_tail.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';

/// Position after 1.e4 — Black to move.
const _leaf = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

ExtractedLine _line({String? leafFen = _leaf}) => ExtractedLine(
  movesSan: const ['e4'],
  movesUci: const ['e2e4'],
  probability: 1.0,
  leafFen: leafFen,
);

TreeBuildConfig _config({int plies = 6, int depth = 0}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  engineTailPlies: plies,
  engineTailDepth: depth,
);

DiscoveryResult _pv(List<String> uci, {int depth = 22}) => DiscoveryResult(
  lines: [DiscoveryLine(pvNumber: 1, depth: depth, scoreCp: 20, pv: uci)],
  depth: depth,
);

void main() {
  group('computeEngineTails', () {
    test('converts the engine PV to SAN, capped at the ply budget', () async {
      final pool = FakeStockfishPool()
        ..discoveryByFen[_leaf] = _pv([
          'e7e5',
          'g1f3',
          'b8c6',
          'f1b5',
          'a7a6',
          'b5a4',
          'g8f6',
        ]);

      final tails = await computeEngineTails(
        lines: [_line()],
        config: _config(plies: 4),
        pool: pool,
      );

      expect(tails[_leaf]!.movesSan, ['e5', 'Nf3', 'Nc6', 'Bb5']);
      expect(tails[_leaf]!.depth, 22);
    });

    test('stops at the first move the position will not accept', () async {
      // A PV that outruns legality — truncated PVs do this.
      final pool = FakeStockfishPool()
        ..discoveryByFen[_leaf] = _pv(['e7e5', 'a1a8', 'b8c6']);

      final tails = await computeEngineTails(
        lines: [_line()],
        config: _config(),
        pool: pool,
      );

      expect(tails[_leaf]!.movesSan, ['e5']);
    });

    test('one search per position however many lines end there', () async {
      final pool = FakeStockfishPool()
        ..discoveryByFen[_leaf] = _pv(['e7e5', 'g1f3']);

      await computeEngineTails(
        lines: [_line(), _line(), _line()],
        config: _config(),
        pool: pool,
      );

      expect(pool.discoverMultiPvCalls, hasLength(1));
    });

    test('searches run across the pool, not one at a time', () async {
      // Six workers and six positions: all six should be in flight, so the
      // slowest single search bounds the pass rather than their sum.
      final pool = FakeStockfishPool(workers: 6);
      final lines = <ExtractedLine>[];
      for (var i = 0; i < 6; i++) {
        final fen = 'fen-$i w - - 0 1';
        lines.add(
          ExtractedLine(
            movesSan: const ['e4'],
            movesUci: const ['e2e4'],
            probability: 1.0,
            leafFen: fen,
          ),
        );
        pool.discoveryByFen[fen] = _pv(const ['e7e5']);
      }

      await computeEngineTails(lines: lines, config: _config(), pool: pool);

      expect(pool.discoverMultiPvCalls, hasLength(6));
    });

    test('0 plies asks the engine nothing at all', () async {
      final pool = FakeStockfishPool();

      final tails = await computeEngineTails(
        lines: [_line()],
        config: _config(plies: 0),
        pool: pool,
      );

      expect(tails, isEmpty);
      expect(pool.discoverMultiPvCalls, isEmpty);
    });

    test('a line with no leaf position is skipped, not guessed at', () async {
      final pool = FakeStockfishPool();

      final tails = await computeEngineTails(
        lines: [_line(leafFen: null)],
        config: _config(),
        pool: pool,
      );

      expect(tails, isEmpty);
      expect(pool.discoverMultiPvCalls, isEmpty);
    });

    test('a failed search costs the tail, never the export', () async {
      // Nothing scripted for this FEN, so the fake throws.
      final pool = FakeStockfishPool();

      final tails = await computeEngineTails(
        lines: [_line()],
        config: _config(),
        pool: pool,
      );

      expect(tails, isEmpty);
    });

    test('cancellation stops before asking the engine', () async {
      final pool = FakeStockfishPool()..discoveryByFen[_leaf] = _pv(['e7e5']);

      final tails = await computeEngineTails(
        lines: [_line()],
        config: _config(),
        pool: pool,
        isCancelled: () => true,
      );

      expect(tails, isEmpty);
      expect(pool.discoverMultiPvCalls, isEmpty);
    });
  });

  group('depth', () {
    test('0 resolves to the verification depth', () {
      expect(_config(depth: 0).resolvedEngineTailDepth, 20);
      expect(
        _config(depth: 0).copyWith(evalDepth: 18).resolvedEngineTailDepth,
        24,
      );
    });

    test('an explicit depth wins', () {
      expect(_config(depth: 30).resolvedEngineTailDepth, 30);
    });
  });
}
