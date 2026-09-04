/// [repertoire_pgn_text] — editing a repertoire's PGN as text.
///
/// These functions were private methods on `RepertoireService`, reachable
/// only through a file on disk. The behaviour they guard is the reason the
/// app edits PGN as text at all: a repertoire game carries headers no PGN
/// serializer models, and losing one of them — `LineID` above all — quietly
/// orphans a line while leaving a file that still looks correct.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/repertoire_pgn_text.dart';

void main() {
  group('reassemblePgnDocument', () {
    test(
      'separates games by a blank line and ends with exactly one newline',
      () {
        expect(
          reassemblePgnDocument('', [
            '[Event "A"]\n1. e4',
            '[Event "B"]\n1. d4',
          ]),
          '[Event "A"]\n1. e4\n\n[Event "B"]\n1. d4\n',
        );
      },
    );

    test('keeps a preamble ahead of the games', () {
      expect(
        reassemblePgnDocument('% comment', ['[Event "A"]']),
        '% comment\n\n[Event "A"]\n',
      );
    });

    test('an empty preamble contributes no leading blank line', () {
      expect(reassemblePgnDocument('', ['[Event "A"]']), '[Event "A"]\n');
    });
  });

  group('withEventTitle', () {
    test('replaces an existing Event header in place', () {
      expect(
        withEventTitle('[Event "Old"]\n[Site "?"]\n1. e4', 'New'),
        '[Event "New"]\n[Site "?"]\n1. e4',
      );
    });

    test('adds the header to a game that has none', () {
      expect(withEventTitle('1. e4', 'New'), '[Event "New"]\n1. e4');
    });
  });

  group('mergeMissingHeaders', () {
    test('restores a LineID the editor dropped', () {
      // The defect: without this, every later lookup by id — rename,
      // autosave, delete — silently fails on a file that looks fine.
      final merged = mergeMissingHeaders(
        '[Event "Line"]\n[LineID "abc123"]\n\n1. e4 e5',
        '[Event "Line"]\n\n1. e4 e5 2. Nf3',
      );
      expect(merged, contains('[LineID "abc123"]'));
      expect(merged, contains('2. Nf3'));
    });

    test('restores review metadata and CumProb too', () {
      final merged = mergeMissingHeaders(
        '[Event "L"]\n[Difficulty "2.50"]\n[CumProb "0.31"]\n\n1. e4',
        '[Event "L"]\n\n1. e4',
      );
      expect(merged, contains('[Difficulty "2.50"]'));
      expect(merged, contains('[CumProb "0.31"]'));
    });

    test('never overwrites a header the new text already has', () {
      final merged = mergeMissingHeaders(
        '[Event "Old"]\n\n1. e4',
        '[Event "New"]\n\n1. e4',
      );
      expect(merged, contains('[Event "New"]'));
      expect(merged, isNot(contains('Old')));
    });

    test('inserts after the last header, not into the movetext', () {
      final merged = mergeMissingHeaders(
        '[Event "L"]\n[LineID "x"]\n\n1. e4',
        '[Event "L"]\n[Site "?"]\n\n1. e4',
      );
      final lines = merged.split('\n');
      expect(lines.indexOf('[LineID "x"]'), lines.indexOf('[Site "?"]') + 1);
    });

    test('a headerless new game gets the headers prepended', () {
      final merged = mergeMissingHeaders('[LineID "x"]\n\n1. e4', '1. e4 e5');
      expect(merged.startsWith('[LineID "x"]'), isTrue);
      expect(merged, contains('1. e4 e5'));
    });

    test('returns the new text untouched when nothing is missing', () {
      const newGame = '[Event "L"]\n\n1. e4';
      expect(mergeMissingHeaders('[Event "L"]\n\n1. e4', newGame), newGame);
    });
  });

  group('gameWithReviewHeaders', () {
    String write(String game) => gameWithReviewHeaders(
      game,
      lastReview: DateTime.utc(2026, 9, 4, 12),
      difficulty: 2.5,
      intervalDays: 6,
      dueDate: DateTime.utc(2026, 9, 10),
      passCount: 3,
      failCount: 1,
    );

    test('writes every review header', () {
      final out = write('[Event "L"]\n\n1. e4 e5');
      expect(out, contains('[Difficulty "2.50"]'));
      expect(out, contains('[Interval "6.00"]'));
      expect(out, contains('[PassCount "3"]'));
      expect(out, contains('[FailCount "1"]'));
      expect(out, contains('[LastReview "2026-09-04T12:00:00.000Z"]'));
      expect(out, contains('[DueDate "2026-09-10T00:00:00.000Z"]'));
    });

    test('a null date is written as empty, not omitted', () {
      final out = gameWithReviewHeaders(
        '[Event "L"]\n\n1. e4',
        lastReview: null,
        difficulty: 2.5,
        intervalDays: 0,
        dueDate: null,
        passCount: 0,
        failCount: 0,
      );
      expect(out, contains('[LastReview ""]'));
      expect(out, contains('[DueDate ""]'));
    });

    test('replaces the old values rather than appending duplicates', () {
      final out = write('[Event "L"]\n[PassCount "99"]\n\n1. e4');
      expect(out, contains('[PassCount "3"]'));
      expect('[PassCount'.allMatches(out).length, 1);
    });

    test('keeps the movetext and the non-review headers', () {
      final out = write('[Event "L"]\n[LineID "keep-me"]\n\n1. e4 e5 2. Nf3');
      expect(out, contains('[LineID "keep-me"]'));
      expect(out, contains('1. e4 e5 2. Nf3'));
    });

    test('puts the standard headers first', () {
      final out = write('[LineID "x"]\n[Event "L"]\n\n1. e4');
      final lines = out.split('\n');
      expect(lines.first, '[Event "L"]');
      expect(lines.indexOf('[LineID "x"]'), lessThan(lines.indexOf('')));
    });
  });

  group('formatNextSan', () {
    test('numbers a White move and leaves a Black move bare', () {
      expect(formatNextSan(const [], 'e4'), '1. e4');
      expect(formatNextSan(const ['e4'], 'e5'), 'e5');
      expect(formatNextSan(const ['e4', 'e5'], 'Nf3'), '2. Nf3');
      expect(formatNextSan(const ['e4', 'e5', 'Nf3'], 'Nc6'), 'Nc6');
    });
  });

  group('appendSanToGamePgn', () {
    test('adds the move and leaves the headers alone', () {
      final out = appendSanToGamePgn(
        '[Event "L"]\n[LineID "x"]\n\n1. e4 e5',
        const ['e4', 'e5'],
        'Nf3',
      );
      expect(out, '[Event "L"]\n[LineID "x"]\n\n1. e4 e5 2. Nf3');
    });

    test('starts the movetext on a game that has none', () {
      expect(
        appendSanToGamePgn('[Event "L"]', const [], 'e4'),
        '[Event "L"]\n\n1. e4',
      );
    });

    test('re-flows a movetext split over several lines', () {
      final out = appendSanToGamePgn(
        '[Event "L"]\n\n1. e4 e5\n2. Nf3 Nc6',
        const ['e4', 'e5', 'Nf3', 'Nc6'],
        'Bb5',
      );
      expect(out, '[Event "L"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5');
    });
  });

  group('buildMinimalGamePgn', () {
    test('names the sides so the trainer knows which one it drills', () {
      final white = buildMinimalGamePgn(const ['e4'], isWhiteRepertoire: true);
      expect(white, contains('[White "Me"]'));
      expect(white, contains('[Black "Opponent"]'));

      final black = buildMinimalGamePgn(const ['e4'], isWhiteRepertoire: false);
      expect(black, contains('[White "Opponent"]'));
      expect(black, contains('[Black "Me"]'));
    });

    test('carries a starting position as FEN plus SetUp', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final out = buildMinimalGamePgn(
        const ['e5'],
        startingFen: fen,
        isWhiteRepertoire: false,
      );
      expect(out, contains('[FEN "$fen"]'));
      expect(out, contains('[SetUp "1"]'));
    });

    test(
      'omits FEN entirely from a game that starts at the initial position',
      () {
        final out = buildMinimalGamePgn(const ['e4'], isWhiteRepertoire: true);
        expect(out, isNot(contains('FEN')));
        expect(out, isNot(contains('SetUp')));
      },
    );

    test('numbers the movetext', () {
      final out = buildMinimalGamePgn(const [
        'e4',
        'e5',
        'Nf3',
      ], isWhiteRepertoire: true);
      expect(out, contains('1. e4 e5 2. Nf3'));
    });
  });
}
