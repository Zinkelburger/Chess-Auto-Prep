/// Position replay over parsed games: FEN lookups, continuations, the
/// inverted position index and its on-disk form.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_slice_filter.dart'
    show parseTargetFen, gameMatchesSequence;
import 'package:chess_auto_prep/utils/chess_utils.dart' show playSanOrNullMove;
import 'package:chess_auto_prep/utils/fen_utils.dart';

void main() {
  group('PgnReplayGame', () {
    const pgn = '[Event "G"]\n\n1. e4 (1. d4 d5) e5 2. Nf3 -- 3. Bc4 *\n';

    test('parses once and answers every replay predicate', () {
      final game = PgnReplayGame.tryParse(const {}, pgn);
      expect(game, isNotNull);
      final afterD5 = normalizeFen(
        Chess.initial
            .play(Chess.initial.parseSan('d4')!)
            .play(
              Chess.initial.play(Chess.initial.parseSan('d4')!).parseSan('d5')!,
            )
            .fen,
      );
      expect(game!.passesThroughFen(afterD5), isTrue);
      expect(
        game.passesThroughFen(afterD5, includeVariations: false),
        isFalse,
        reason: 'd5 lives only in the sideline',
      );
      expect(game.mainlineSans, ['e4', 'e5', 'Nf3', 'Bc4']);
    });

    test('a game whose FEN header does not parse matches nothing', () {
      expect(PgnReplayGame.tryParse(const {'FEN': 'garbage'}, pgn), isNull);
    });

    test('startPositionFromGame honours a FEN header without SetUp', () {
      final game = PgnGame.parsePgn('[FEN "8/8/8/8/8/8/8/K6k w - - 0 1"]\n\n*');
      expect(startPositionFromGame(game).fen, '8/8/8/8/8/8/8/K6k w - - 0 1');
    });
  });

  group('mainlineSansAfterFen', () {
    const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    String fenAfter(List<String> sans) {
      Position pos = Chess.initial;
      for (final san in sans) {
        final move = pos.parseSan(san);
        if (move == null) {
          throw StateError('illegal SAN $san');
        }
        pos = pos.play(move);
      }
      return pos.fen;
    }

    test('returns the full mainline from the starting position', () {
      expect(
        mainlineSansAfterFen(const {}, '1. e4 e5 2. Nf3 Nc6 *', startFen),
        ['e4', 'e5', 'Nf3', 'Nc6'],
      );
    });

    test('returns remaining SAN after a mid-game FEN, without comments', () {
      const pgn = '1. e4 {best} e5 {reply} 2. Nf3 (2. d4) Nc6 *';
      expect(mainlineSansAfterFen(const {}, pgn, fenAfter(['e4'])), [
        'e5',
        'Nf3',
        'Nc6',
      ]);
    });

    test('returns empty when the FEN is never reached', () {
      expect(
        mainlineSansAfterFen(const {}, '1. e4 e5 *', 'not-a-fen'),
        isEmpty,
      );
    });

    test('caps remaining plies', () {
      expect(
        mainlineSansAfterFen(
          const {},
          '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *',
          startFen,
          maxPlies: 3,
        ),
        ['e4', 'e5', 'Nf3'],
      );
    });

    test('a repeated position answers with its first continuation', () {
      // 1.Nf3 Nf6 2.Ng1 Ng8 returns to the starting position. The walk has to
      // stop at the first time the target is reached, or a shuffle at the
      // start of a game silently truncates the line the reader is shown.
      const pgn = '1. Nf3 Nf6 2. Ng1 Ng8 3. e4 *';
      expect(mainlineSansAfterFen(const {}, pgn, startFen), [
        'Nf3',
        'Nf6',
        'Ng1',
        'Ng8',
        'e4',
      ]);
    });

    test('a position the game never reaches yields nothing', () {
      Position pos = Chess.initial;
      for (final san in ['d4', 'd5']) {
        pos = pos.play(pos.parseSan(san)!);
      }
      const pgn = '1. e4 e5 2. Nf3 *';
      expect(
        mainlineSansAfterFen(const {}, pgn, normalizeFen(pos.fen)),
        isEmpty,
      );
      expect(
        gamePassesThroughFen(const {}, pgn, normalizeFen(pos.fen)),
        isFalse,
        reason: 'the game never plays 1.d4',
      );
      expect(
        gamePassesThroughFen(const {}, pgn, normalizeFen(Chess.initial.fen)),
        isTrue,
      );
    });
  });

  group('ChessBase / Chessable null moves (Z0 / --)', () {
    const colle = '1. d4 Z0 2. Nf3 Z0 3. e3 *';

    String fenAfter(List<String> sans) {
      Position pos = Chess.initial;
      for (final san in sans) {
        pos = playSanOrNullMove(pos, san)!;
      }
      return pos.fen;
    }

    test('parseTargetFen replays Z0 as a pass', () {
      final fen = parseTargetFen('d4 Z0 Nf3');
      expect(fen, normalizeFen(fenAfter(['d4', '--', 'Nf3'])));
    });

    test('gamePassesThroughFen reaches positions after a Z0 pass', () {
      expect(
        gamePassesThroughFen(const {}, colle, normalizeFen(fenAfter(['d4']))),
        isTrue,
      );
      expect(
        gamePassesThroughFen(
          const {},
          colle,
          normalizeFen(fenAfter(['d4', '--', 'Nf3'])),
        ),
        isTrue,
      );
    });

    test('buildFenIndex records positions after null-move passes', () {
      final index = buildFenIndex([(headers: const {}, pgnText: colle)]);
      expect(index[normalizeFen(fenAfter(['d4', '--', 'Nf3']))], [0]);
    });

    test('mainlineSansAfterFen keeps going past Z0', () {
      expect(mainlineSansAfterFen(const {}, colle, Chess.initial.fen), [
        'd4',
        '--',
        'Nf3',
        '--',
        'e3',
      ]);
    });

    test('gameMatchesSequence ignores Z0 tokens in the mainline', () {
      expect(
        gameMatchesSequence(colle, [
          ['d4', 'Nf3', 'e3'],
        ], 4),
        isTrue,
      );
    });

    test('gamePassesThroughFen finds a position that lives only in a RAV', () {
      const pgn = '1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *';
      final afterC5 = normalizeFen(fenAfter(['e4', 'c5']));
      expect(gamePassesThroughFen(const {}, pgn, afterC5), isTrue);
      expect(buildFenIndex([(headers: const {}, pgnText: pgn)])[afterC5], [0]);
      expect(mainlineSansAfterFen(const {}, pgn, afterC5), ['Nf3']);
    });

    test('promoted Chessable intro is indexed on the lesson moves', () {
      const intro =
          '1. Z0 ({Welcome} 1. d4 {We intend to play} Z0 2. Nf3 {and} '
          'Z0 3. e3 {next.}) *';
      final afterD4 = normalizeFen(fenAfter(['d4']));
      expect(gamePassesThroughFen(const {}, intro, afterD4), isTrue);
      expect(mainlineSansAfterFen(const {}, intro, Chess.initial.fen), [
        'd4',
        '--',
        'Nf3',
        '--',
        'e3',
      ]);
    });
  });

  group('FEN index round trip', () {
    const gameCount = 2;
    const fileSize = 1234;
    const modifiedMs = 99999;

    String blobOf(Map<String, List<int>> index) => serializeFenIndex(
      index,
      gameCount: gameCount,
      fileSize: fileSize,
      modifiedMs: modifiedMs,
    );

    Map<String, List<int>>? readBack(String blob) => deserializeFenIndex(
      blob,
      expectedGameCount: gameCount,
      expectedFileSize: fileSize,
      expectedModifiedMs: modifiedMs,
    );

    test('a serialized index reads back unchanged', () {
      final index = {
        'a/fen w - -': [0, 1],
        'b/fen b - -': [1],
      };
      expect(readBack(blobOf(index)), index);
    });

    test('a header we did not write forces a rebuild', () {
      final good = blobOf({
        'a/fen w - -': [0],
      });
      const header = 'FENIDX3 $gameCount $fileSize $modifiedMs';
      expect(readBack(good), isNotNull);
      expect(readBack(good.replaceFirst('FENIDX3', 'FENIDX2')), isNull);
      expect(
        readBack(good.replaceFirst(header, '$header 99')),
        isNull,
        reason: 'an extra header field is not a format we can trust',
      );
      expect(
        readBack(good.replaceFirst(header, 'FENIDX3 $gameCount $fileSize')),
        isNull,
        reason: 'a truncated header is not a format we can trust',
      );
    });
  });
}
