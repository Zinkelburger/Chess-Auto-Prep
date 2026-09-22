/// Chapter titles read off game headers: which header carries them, which
/// one names the line, and what disqualifies a file from being a course.
library;

import 'package:chess_auto_prep/chess_core/pgn/course_chapter_headers.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _game({
  String white = '?',
  String black = '?',
  String event = '?',
  String result = '*',
}) => {'White': white, 'Black': black, 'Event': event, 'Result': result};

void main() {
  group('detectHeaderChapters', () {
    test('titles must group games and cover most of the file', () {
      final course = [
        _game(white: 'Ch 1', black: 'Line a'),
        _game(white: 'Ch 1', black: 'Line b'),
        _game(white: 'Ch 2', black: 'Line c'),
      ];
      expect(detectHeaderChapters(course), ['Ch 1', 'Ch 1', 'Ch 2']);
      expect(
        detectHeaderChapters(course, key: 'Black'),
        isNull,
        reason: 'every title is distinct',
      );
    });

    test('decisive results and placeholder names are not chapters', () {
      expect(
        detectHeaderChapters([
          _game(white: 'Carlsen', result: '1-0'),
          _game(white: 'Carlsen', result: '1-0'),
          _game(white: 'Nakamura', result: '0-1'),
        ]),
        isNull,
      );
      expect(
        detectHeaderChapters([
          _game(white: 'Me'),
          _game(white: 'Me'),
          _game(white: 'Opponent'),
        ]),
        isNull,
      );
    });

    test('a self-described course needs no repeated title', () {
      expect(
        detectHeaderChapters([
          _game(white: 'Ch 1'),
          {..._game(white: 'Model games'), 'ModelGameWhite': 'Fischer'},
        ]),
        ['Ch 1', 'Model games'],
      );
    });
  });

  group('chapterHeaderKey', () {
    test('picks the header whose values change least often', () {
      expect(
        chapterHeaderKey([
          _game(white: 'Line a', black: 'Ch 1'),
          _game(white: 'Line b', black: 'Ch 1'),
          _game(white: 'Line a', black: 'Ch 2'),
          _game(white: 'Line b', black: 'Ch 2'),
        ]),
        'Black',
      );
      expect(
        chapterHeaderKey([
          _game(white: 'Line a', event: 'Ch 1'),
          _game(white: 'Line b', event: 'Ch 1'),
          _game(white: 'Line c', event: 'Ch 2'),
          _game(white: 'Line d', event: 'Ch 2'),
        ]),
        'Event',
      );
      expect(chapterHeaderKey([_game(), _game()]), isNull);
    });

    test('the title header is the other player header', () {
      expect(titleHeaderKeyFor('White'), 'Black');
      expect(titleHeaderKeyFor('Black'), 'White');
      expect(titleHeaderKeyFor('Event'), 'White');
      expect(titleHeaderKeyFor(null), 'Black');
    });
  });

  test('isModelGamesChapterTitle', () {
    expect(isModelGamesChapterTitle('Model Games'), isTrue);
    expect(isModelGamesChapterTitle('Chapter 9: model game'), isTrue);
    expect(isModelGamesChapterTitle('Remodel games'), isFalse);
    expect(isModelGamesChapterTitle(''), isFalse);
  });
}
