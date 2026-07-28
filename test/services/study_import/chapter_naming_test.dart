import 'package:chess_auto_prep/services/study_import/chapter_naming.dart';
import 'package:chess_auto_prep/services/study_import/lichess_study_client.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart'
    show extractHeaders, splitPgnIntoGames;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('withEventHeader', () {
    test('replaces an existing Event tag', () {
      const pgn = '[Event "Old"]\n[Site "?"]\n\n1. e4 *\n';
      expect(withEventHeader(pgn, 'New'), contains('[Event "New"]'));
      expect(withEventHeader(pgn, 'New'), isNot(contains('Old')));
      expect(withEventHeader(pgn, 'New'), contains('[Site "?"]'));
    });

    test('inserts one when the game has no Event tag', () {
      const pgn = '[Site "?"]\n\n1. e4 *\n';
      expect(withEventHeader(pgn, 'New'), startsWith('[Event "New"]\n[Site'));
    });

    test('escapes quotes and backslashes', () {
      const pgn = '[Event "Old"]\n\n1. e4 *\n';
      expect(
        withEventHeader(pgn, r'He said "hi" \ bye'),
        contains(r'[Event "He said \"hi\" \\ bye"]'),
      );
    });

    test('replaces only the first Event tag', () {
      const twoGames = '[Event "A"]\n\n1. e4 *\n\n[Event "B"]\n\n1. d4 *\n';
      final out = withEventHeader(twoGames, 'X');
      expect(out, contains('[Event "X"]'));
      expect(out, contains('[Event "B"]'));
    });
  });

  group('gameChapterName', () {
    test('players, event, year and result', () {
      expect(
        gameChapterName(const {
          'White': 'Fischer, R',
          'Black': 'Spassky, B',
          'Event': 'World Championship',
          'Date': '1972.07.11',
          'Result': '1-0',
        }, fallback: 'Game 1'),
        'Fischer, R - Spassky, B, World Championship 1972 (1-0)',
      );
    });

    test('does not repeat a year already in the event name', () {
      expect(
        gameChapterName(const {
          'White': 'Tal',
          'Black': 'Botvinnik',
          'Event': 'World Championship 1960',
          'Date': '1960.03.15',
          'Result': '*',
        }, fallback: 'Game 1'),
        'Tal - Botvinnik, World Championship 1960',
      );
    });

    test('treats "?" as absent', () {
      expect(
        gameChapterName(const {
          'White': 'Tal',
          'Black': 'Botvinnik',
          'Event': '?',
          'Date': '????.??.??',
          'Result': '?',
        }, fallback: 'Game 7'),
        'Tal - Botvinnik',
      );
    });

    test('falls back when there is nothing to name it after', () {
      expect(gameChapterName(const {}, fallback: 'Game 7'), 'Game 7');
    });

    test('omits an unfinished result marker', () {
      expect(
        gameChapterName(const {
          'White': 'A',
          'Black': 'B',
          'Result': '*',
        }, fallback: 'Game 1'),
        'A - B',
      );
    });
  });

  group('splitLichessStudyName', () {
    /// Lichess stamps "<study>: <chapter>" into every exported Event tag.
    String lichessPgn(List<String> events) => events
        .map((e) => '[Event "$e"]\n[Result "*"]\n\n1. e4 e5 *\n')
        .join('\n');

    test('lifts the shared prefix out into the study name', () {
      final result = splitLichessStudyName(
        lichessPgn(['My Repertoire: Italian', 'My Repertoire: Scotch']),
      );
      expect(result.studyName, 'My Repertoire');

      final names = splitPgnIntoGames(
        result.pgn,
      ).map((g) => extractHeaders(g)['Event']).toList();
      expect(names, ['Italian', 'Scotch']);
    });

    test('leaves the PGN alone when chapters disagree on the prefix', () {
      final pgn = lichessPgn(['Study A: One', 'Study B: Two']);
      final result = splitLichessStudyName(pgn);
      expect(result.studyName, isNull);
      expect(result.pgn, pgn);
    });

    test('leaves the PGN alone when there is no prefix at all', () {
      final pgn = lichessPgn(['Just a chapter name']);
      final result = splitLichessStudyName(pgn);
      expect(result.studyName, isNull);
      expect(result.pgn, pgn);
    });

    test('a chapter name that itself contains a colon splits on the first', () {
      final result = splitLichessStudyName(
        lichessPgn(['Repertoire: Sicilian: Najdorf']),
      );
      expect(result.studyName, 'Repertoire');
      expect(
        extractHeaders(splitPgnIntoGames(result.pgn).single)['Event'],
        'Sicilian: Najdorf',
      );
    });

    test('empty PGN is passed through', () {
      final result = splitLichessStudyName('');
      expect(result.studyName, isNull);
      expect(result.pgn, '');
    });
  });
}
