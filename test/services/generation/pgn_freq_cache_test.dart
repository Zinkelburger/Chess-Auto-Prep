// Round-trip and invalidation tests for the PGN frequency-map disk cache.
//
// The cache is the difference between a repertoire rebuild taking seconds and
// taking minutes, and a *stale* hit would silently generate against the wrong
// database — so both the round trip and every invalidation path are pinned.

import 'dart:io';

import 'package:chess_auto_prep/services/generation/pgn_freq_cache.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:flutter_test/flutter_test.dart';

const _fenA = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
const _fenB = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3';

PgnFreqMap _sampleMap() {
  final map = PgnFreqMap()..totalGames = 3;
  map
    ..recordReach(_fenA)
    ..recordMove(
      _fenA,
      'e2e4',
      'e4',
      outcome: GameOutcome.whiteWin,
      averageElo: 2600,
      year: 2019,
    )
    ..recordMove(
      _fenA,
      'e2e4',
      'e4',
      outcome: GameOutcome.draw,
      averageElo: 2400,
      year: 2023,
    )
    ..recordMove(_fenA, 'd2d4', 'd4', outcome: GameOutcome.blackWin)
    ..recordReach(_fenB);
  map.games.addAllUnchecked([
    PgnGameRecord(
      white: 'Nepomniachtchi, I',
      black: 'Ding, L',
      whiteElo: 2795,
      blackElo: 2788,
      event: 'World Championship',
      date: '2023.04.09',
      outcome: GameOutcome.blackWin,
      movesSan: const ['e4', 'e5', 'Nf3'],
    ),
  ]);
  map.getOrCreate(_fenA).addGameRef(0);
  return map;
}

void main() {
  late Directory dir;
  late String cachePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('freq_cache_test');
    cachePath = '${dir.path}/games.pgn.freq.cache';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('PgnFreqCache', () {
    test('round-trips positions, outcomes, ratings and recency', () {
      expect(savePgnFreqCache(_sampleMap(), cachePath, 'manifest'), isTrue);

      final loaded = loadPgnFreqCache(cachePath, 'manifest')!;

      expect(loaded.totalGames, 3);
      expect(loaded.positionCount, 2);

      final e4 = loaded.get(_fenA)!.move('e2e4')!;
      expect(e4.san, 'e4');
      expect(e4.count, 2);
      expect(e4.whiteWins, 1);
      expect(e4.draws, 1);
      expect(e4.averageElo, 2500);
      expect(e4.lastYear, 2023, reason: 'the most recent year wins');
      expect(e4.scoreFor(asWhite: true), 0.75);

      final d4 = loaded.get(_fenA)!.move('d2d4')!;
      expect(d4.blackWins, 1);
      expect(d4.averageElo, isNull, reason: 'no ratings were recorded');
    });

    test('round-trips retained games and their back-references', () {
      savePgnFreqCache(_sampleMap(), cachePath, 'manifest');

      final loaded = loadPgnFreqCache(cachePath, 'manifest')!;

      expect(loaded.games.length, 1);
      final game = loaded.games.entries.single;
      expect(game.white, 'Nepomniachtchi, I');
      expect(game.averageElo, 2791);
      expect(game.year, 2023);
      expect(game.outcome, GameOutcome.blackWin);
      expect(game.wonBy(asWhite: false), isTrue);
      expect(game.movesSan, ['e4', 'e5', 'Nf3']);
      expect(loaded.get(_fenA)!.gameRefs, [0]);
    });

    test('rejects a cache written under a different manifest', () {
      savePgnFreqCache(_sampleMap(), cachePath, 'manifest-v1');

      expect(loadPgnFreqCache(cachePath, 'manifest-v2'), isNull);
    });

    test('returns null for a missing file', () {
      expect(loadPgnFreqCache('${dir.path}/absent.cache', 'm'), isNull);
    });

    test('returns null for a truncated or corrupt file', () {
      savePgnFreqCache(_sampleMap(), cachePath, 'manifest');
      final bytes = File(cachePath).readAsBytesSync();
      File(cachePath).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));

      expect(loadPgnFreqCache(cachePath, 'manifest'), isNull);
    });

    test('returns null when the magic header is wrong', () {
      File(cachePath).writeAsBytesSync(List.filled(64, 0));

      expect(loadPgnFreqCache(cachePath, 'manifest'), isNull);
    });

    test('preserves long SAN and FEN keys without truncating', () {
      // The previous fixed-width format capped SAN at 16 bytes and FEN keys
      // at 128; a promotion-with-check in a long FEN is the realistic case.
      final map = PgnFreqMap()
        ..recordMove(_fenB, 'a7a8q', 'axb8=Q+', outcome: GameOutcome.whiteWin);
      savePgnFreqCache(map, cachePath, 'm');

      final loaded = loadPgnFreqCache(cachePath, 'm')!;
      expect(loaded.get(_fenB)!.move('a7a8q')!.san, 'axb8=Q+');
    });

    test('the manifest changes when a parse setting changes', () {
      final stat = File('${dir.path}/games.pgn')
        ..writeAsStringSync('[Event "x"]');
      final base = buildPgnFreqManifest(
        path: stat.path,
        stat: stat.statSync(),
        config: const PgnFreqConfig(maxPly: 20),
      );
      final deeper = buildPgnFreqManifest(
        path: stat.path,
        stat: stat.statSync(),
        config: const PgnFreqConfig(maxPly: 30),
      );
      final fewerGames = buildPgnFreqManifest(
        path: stat.path,
        stat: stat.statSync(),
        config: const PgnFreqConfig(maxPly: 20, retainGames: 8),
      );

      expect(base, isNot(deeper));
      expect(base, isNot(fewerGames));
    });
  });

  group('TopGamesReservoir', () {
    PgnGameRecord game(int elo) => PgnGameRecord(
      white: 'W$elo',
      black: 'B',
      whiteElo: elo,
      blackElo: elo,
      event: '',
      date: '',
      outcome: null,
      movesSan: const ['e4'],
    );

    test('keeps the strongest games once compacted', () {
      final reservoir = TopGamesReservoir(capacity: 3);
      for (final elo in [2100, 2700, 2300, 2600, 2200, 2500]) {
        reservoir.offer(game(elo));
      }
      reservoir.finalize();

      expect(reservoir.entries.map((g) => g.averageElo), [
        2700,
        2600,
        2500,
      ], reason: 'strongest first, capacity respected');
    });

    test('rejects candidates below the admission bar without storing them', () {
      final reservoir = TopGamesReservoir(capacity: 2);
      for (final elo in [2700, 2600, 2500, 2400]) {
        reservoir.offer(game(elo));
      }
      reservoir.finalize();

      expect(reservoir.admissionElo, 2600);
      expect(reservoir.offer(game(2000)), isNull);
      expect(reservoir.length, 2);
    });

    test('finalize reports how surviving entries moved', () {
      final reservoir = TopGamesReservoir(capacity: 2);
      reservoir.offer(game(2100));
      reservoir.offer(game(2700));
      reservoir.offer(game(2400));

      final remap = reservoir.finalize();

      expect(remap[1], 0, reason: '2700 was offered second, now ranks first');
      expect(remap[2], 1);
      expect(remap.containsKey(0), isFalse, reason: '2100 was evicted');
    });
  });
}
