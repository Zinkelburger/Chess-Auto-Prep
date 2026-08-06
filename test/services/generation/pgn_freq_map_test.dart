// WS-A characterization tests for PgnFreqMap (previously untested, 675 LOC).
// Pins the in-memory frequency-map behavior: record, dedup, canonical lookup,
// filtering, and merge.

import 'dart:io';

import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_parser.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  group('PgnFreqMap.recordMove', () {
    test('dedups by UCI and increments count', () {
      final m = PgnFreqMap();
      final key = canonicalizeFen4(_fen);
      m.recordMove(key, 'e2e4', 'e4');
      m.recordMove(key, 'e2e4', 'e4');
      m.recordMove(key, 'd2d4', 'd4');

      final pos = m.get(_fen)!;
      expect(pos.moves.length, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'e2e4').count, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'd2d4').count, 1);
    });

    test(
      'get() resolves via canonical 4-field FEN (ignores move counters)',
      () {
        final m = PgnFreqMap();
        m.recordMove(canonicalizeFen4(_fen), 'e2e4', 'e4');
        // Query with different counters — same position.
        final other = _fen.replaceAll('0 1', '3 9');
        expect(m.get(other), isNotNull);
      },
    );
  });

  group('PgnFreqMap.recordReach', () {
    test('counts reaches per position', () {
      final m = PgnFreqMap();
      final key = canonicalizeFen4(_fen);
      m.recordReach(key);
      m.recordReach(key);
      expect(m.get(_fen)!.reachCount, 2);
    });
  });

  group('PgnFreqMap.filteredMoves', () {
    test('drops moves below minGames and below minProb', () {
      final m = PgnFreqMap();
      final key = canonicalizeFen4(_fen);
      for (var i = 0; i < 8; i++) {
        m.recordMove(key, 'e2e4', 'e4');
      }
      m.recordMove(key, 'd2d4', 'd4'); // 1/9 ≈ 0.11
      m.recordMove(key, 'c2c4', 'c4'); // 1/10 after next… keep simple

      final pos = m.get(_fen)!;
      // minGames=2 removes the singletons; e4 (8) survives.
      final byGames = m.filteredMoves(pos, minGames: 2, minProb: 0.0);
      expect(byGames.map((x) => x.uci), ['e2e4']);

      // minProb=0.2 keeps only moves with >=20% share.
      final byProb = m.filteredMoves(pos, minGames: 1, minProb: 0.2);
      expect(byProb.map((x) => x.uci), ['e2e4']);
    });

    test('returns empty when position has no moves', () {
      final m = PgnFreqMap();
      m.recordReach(canonicalizeFen4(_fen));
      final pos = m.get(_fen)!;
      expect(m.filteredMoves(pos, minGames: 1, minProb: 0.0), isEmpty);
    });
  });

  group('PgnFreqMap.merge', () {
    test('sums move counts, reach counts, and totalGames', () {
      final key = canonicalizeFen4(_fen);
      final a = PgnFreqMap()
        ..totalGames = 3
        ..recordMove(key, 'e2e4', 'e4')
        ..recordReach(key);
      final b = PgnFreqMap()
        ..totalGames = 2
        ..recordMove(key, 'e2e4', 'e4')
        ..recordMove(key, 'd2d4', 'd4')
        ..recordReach(key);

      a.merge(b);

      expect(a.totalGames, 5);
      final pos = a.get(_fen)!;
      expect(pos.reachCount, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'e2e4').count, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'd2d4').count, 1);
    });
  });

  group('parsePgnFiles', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pgn_freq_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    String writePgn(String content) {
      final file = File('${tmp.path}/games.pgn');
      file.writeAsStringSync(content);
      return file.path;
    }

    test('accumulates move frequencies from movetext', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 2. Nf3 {a comment} Nc6 (2... d6 3. d4) 1-0

[White "C"]
[Black "D"]
[Result "0-1"]

1. e4 c5 0-1
''');

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(),
        useDiskCache: false,
      );

      expect(stats.totalGames, 2);
      expect(stats.parseErrors, 0);

      final root = map.get(_fen)!;
      expect(root.moves.single.uci, 'e2e4');
      expect(root.moves.single.count, 2);

      // Variation "(2... d6 3. d4)" must be skipped, comment ignored.
      final afterNf3 = map.get(
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3',
      );
      expect(afterNf3, isNotNull);
      expect(afterNf3!.reachCount, 1);
    });

    test('startMoves prefix skips games that never reach it', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]

1. e4 e5 *

[White "C"]
[Black "D"]

1. d4 d5 *
''');

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(startMoves: 'e4'),
        useDiskCache: false,
      );

      expect(stats.totalGames, 1);
      expect(stats.skippedPrefix, 1);
      // Frequency tracking starts at the post-e4 position.  Derive its FEN
      // with dartchess so the en-passant field matches what parsing stores.
      expect(map.get(_fen), isNull);
      final afterE4Fen = Chess.initial.play(Move.parse('e2e4')!).fen;
      final afterE4 = map.get(afterE4Fen);
      expect(afterE4!.moves.single.san, 'e5');
    });

    test('counts games with unparseable moves as parse errors', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]

1. e4 Nxe4 *

[White "C"]
[Black "D"]

1. e4 e5 *
''');

      final (_, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(),
        useDiskCache: false,
      );

      expect(stats.totalGames, 1);
      expect(stats.parseErrors, 1);
    });

    test('records results, ratings and recency per move', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]
[WhiteElo "2600"]
[BlackElo "2400"]
[Date "2019.03.01"]
[Result "1-0"]

1. e4 e5 1-0

[White "C"]
[Black "D"]
[WhiteElo "2500"]
[BlackElo "2500"]
[Date "2023.11.20"]
[Result "1/2-1/2"]

1. e4 c5 1/2-1/2

[White "E"]
[Black "F"]
[Result "0-1"]

1. e4 e5 0-1
''');

      final (map, _) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(),
        useDiskCache: false,
      );

      final e4 = map.get(_fen)!.move('e2e4')!;
      expect(e4.count, 3);
      expect(e4.whiteWins, 1);
      expect(e4.draws, 1);
      expect(e4.blackWins, 1);
      expect(e4.scoreFor(asWhite: true), 0.5);
      // Only the two rated games contribute: (2500 + 2500) / 2.
      expect(e4.averageElo, 2500);
      expect(e4.lastYear, 2023);
    });

    test('a move with no recorded results reports no score', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]
[Result "*"]

1. e4 e5 *
''');

      final (map, _) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(),
        useDiskCache: false,
      );

      final e4 = map.get(_fen)!.move('e2e4')!;
      expect(e4.count, 1);
      expect(e4.decidedGames, 0);
      expect(
        e4.scoreFor(asWhite: true),
        isNull,
        reason: 'an unmeasured score must not look like an even one',
      );
    });

    test('retains the strongest games whole for model-game selection', () async {
      final path = writePgn('''
[White "Strong, A"]
[Black "Strong, B"]
[WhiteElo "2700"]
[BlackElo "2700"]
[Result "1-0"]

1. e4 e5 2. Nf3 1-0

[White "Weak, A"]
[Black "Weak, B"]
[WhiteElo "1400"]
[BlackElo "1400"]
[Result "0-1"]

1. e4 c5 0-1
''');

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(retainGames: 1),
        useDiskCache: false,
      );

      expect(stats.retainedGames, 1);
      final kept = map.games.entries.single;
      expect(kept.white, 'Strong, A');
      expect(kept.movesSan, ['e4', 'e5', 'Nf3']);
      expect(kept.averageElo, 2700);
      // The root position must still point at the game that passed through it.
      expect(map.get(_fen)!.gameRefs, [0]);
    });

    test('retainGames 0 skips retention entirely', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]

1. e4 e5 *
''');

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(retainGames: 0),
        useDiskCache: false,
      );

      expect(stats.retainedGames, 0);
      expect(map.games.isEmpty, isTrue);
      expect(map.get(_fen)!.moves, isNotEmpty, reason: 'counts still recorded');
    });

    test('retains a whole game past the depth statistics stop at', () async {
      // The Opera Game: 33 plies, far past any repertoire build depth.
      final path = writePgn('''
[White "Morphy, P"]
[Black "Duke of Brunswick"]
[WhiteElo "2600"]
[BlackElo "2400"]
[Result "1-0"]

1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7
8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7
14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
''');

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(maxPly: 6, retainGames: 4),
        useDiskCache: false,
      );

      expect(stats.retainedGames, 1);
      expect(
        map.games.entries.single.movesSan.length,
        33,
        reason: 'a model game truncated at the build depth teaches nothing',
      );

      // Statistics still stop where they were asked to.
      final counted = map.positions.fold<int>(
        0,
        (sum, e) => sum + e.value.moves.fold<int>(0, (a, m) => a + m.count),
      );
      expect(counted, 6);
    });

    test('a broken move past the counted depth truncates, not voids', () async {
      final path = writePgn('''
[White "A"]
[Black "B"]

1. e4 e5 2. Nf3 Nc6 3. Qxh8 *
''');

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(maxPly: 2, retainGames: 4),
        useDiskCache: false,
      );

      expect(stats.parseErrors, 0, reason: 'the opening scanned cleanly');
      expect(stats.totalGames, 1);
      expect(map.games.entries.single.movesSan, ['e4', 'e5', 'Nf3', 'Nc6']);
    });

    test(
      'retention keeps its own rating floor, below which nothing is kept',
      () async {
        final path = writePgn('''
[White "Club, A"]
[Black "Club, B"]
[WhiteElo "1500"]
[BlackElo "1600"]

1. e4 e5 *
''');

        final (map, stats) = await parsePgnFiles(
          paths: [path],
          config: const PgnFreqConfig(retainGames: 4, retainMinElo: 2200),
          useDiskCache: false,
        );

        expect(stats.retainedGames, 0);
        expect(
          map.get(_fen)!.moves,
          isNotEmpty,
          reason: 'the floor governs model games, not the frequency sample',
        );
      },
    );

    test('an unrated game clears the retention floor', () async {
      final path = writePgn('''
[White "Morphy, P"]
[Black "Duke of Brunswick"]

1. e4 e5 *
''');

      final (map, _) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(retainGames: 4, retainMinElo: 2200),
        useDiskCache: false,
      );

      expect(map.games.entries.single.white, 'Morphy, P');
    });

    test('reports missing file as a file read error, not a hang', () async {
      final (_, stats) = await parsePgnFiles(
        paths: ['${tmp.path}/does_not_exist.pgn'],
        config: const PgnFreqConfig(),
        useDiskCache: false,
      );

      expect(stats.totalGames, 0);
      expect(stats.fileReadErrors, 1);
    });
  });
}
