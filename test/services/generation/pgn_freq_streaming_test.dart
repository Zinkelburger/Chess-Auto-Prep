import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frequency scanner streams a file in fixed chunks instead of decoding
/// it whole.  These pin the seams that streaming introduces: a game or a
/// multi-byte character straddling a chunk boundary, the whole-file Latin-1
/// fallback, and a splitter that is fed line by line.
void main() {
  const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('pgn_freq_stream'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String game(int i, String moves, {String white = 'Player', int elo = 2500}) =>
      '[Event "Test $i"]\n[White "$white"]\n[Black "B"]\n[Result "1-0"]\n'
      '[WhiteElo "$elo"]\n[BlackElo "$elo"]\n\n$moves 1-0\n\n';

  group('PgnGameSplitter', () {
    test('agrees with splitPgnGames when fed line by line', () {
      final text =
          '${game(1, '1. e4 e5 2. Nf3')}'
          '[Event "no blank line before"]\n1. d4 d5\n'
          '${game(3, '1. c4')}';

      final whole = splitPgnGames(text);
      final streamed = <PgnGame>[];
      final splitter = PgnGameSplitter(streamed.add);
      for (final line in text.split('\n')) {
        splitter.addLine(line);
      }
      splitter.close();

      expect(streamed.length, whole.length);
      expect(streamed.length, 3);
      for (var i = 0; i < whole.length; i++) {
        expect(streamed[i].headers, whole[i].headers);
        expect(streamed[i].movetext, whole[i].movetext);
      }
      expect(streamed[1].movetext, '1. d4 d5');
    });
  });

  group('tokenizeMovetext', () {
    test('skips comments, variations and NAGs on code units', () {
      expect(
        tokenizeMovetext(
          r'1. e4 {best} e5 (1... c5 {Sicilian} 2. Nf3 (2. c3)) $1 2. Nf3 *',
        ),
        ['1.', 'e4', 'e5', '2.', 'Nf3', '*'],
      );
      expect(tokenToSan('12.Nf3'), 'Nf3');
      expect(tokenToSan('1...c5'), 'c5');
      expect(tokenToSan('12.'), isNull);
      expect(tokenToSan('O-O'), 'O-O');
    });
  });

  group('parsePgnFiles streaming', () {
    test('counts every game in a file larger than one read chunk', () async {
      // ~4.5 MB: comfortably past the 4 MiB chunk so at least one game and
      // one line straddle a chunk boundary.
      final buffer = StringBuffer();
      var i = 0;
      while (buffer.length < 4500000) {
        buffer.write(game(i++, '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6'));
      }
      final path = '${tmp.path}/big.pgn';
      File(path).writeAsStringSync(buffer.toString());

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(),
        useDiskCache: false,
      );

      expect(stats.totalGames, i);
      expect(stats.parseErrors, 0);
      expect(map.get(startFen)!.moves.single.count, i);
    });

    test('decodes UTF-8 headers that straddle a chunk boundary', () async {
      // Pad so the multi-byte name lands right around the 4 MiB mark.
      final pad = StringBuffer();
      var n = 0;
      // Padding games are weak so the retained-games reservoir keeps the
      // one whose name we check.
      while (pad.length < (4 << 20) - 60) {
        pad.write(game(n++, '1. d4 d5', elo: 1200));
      }
      final text =
          '$pad${game(n, '1. e4 c5', white: 'Ünal Şükrü Ærø', elo: 2600)}';
      final path = '${tmp.path}/utf8.pgn';
      File(path).writeAsBytesSync(utf8.encode(text));

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(retainGames: 4),
        useDiskCache: false,
      );

      expect(stats.totalGames, n + 1);
      expect(stats.parseErrors, 0);
      expect(map.get(startFen)!.moves.map((m) => m.uci), contains('e2e4'));
      expect(map.games.length, greaterThan(0));
      expect(
        map.games.entries.any((g) => g.white == 'Ünal Şükrü Ærø'),
        isTrue,
        reason: 'the name spans the chunk seam and must survive intact',
      );
    });

    test('falls back to Latin-1 for a file that is not valid UTF-8', () async {
      final path = '${tmp.path}/latin1.pgn';
      File(
        path,
      ).writeAsBytesSync(latin1.encode(game(1, '1. e4 e5', white: 'Müller')));

      final (map, stats) = await parsePgnFiles(
        paths: [path],
        config: const PgnFreqConfig(retainGames: 4),
        useDiskCache: false,
      );

      expect(stats.totalGames, 1);
      expect(stats.fileReadErrors, 0);
      expect(map.games.entries.single.white, 'Müller');
    });
  });
}
