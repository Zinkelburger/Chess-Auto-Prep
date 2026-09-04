import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PgnGameEntry.label', () {
    test('player games stay White vs Black', () {
      expect(
        PgnGameEntry(
          headers: {
            'White': 'Carlsen, Magnus',
            'Black': 'Nakamura, Hikaru',
            'Result': '1-0',
          },
          pgnText: '',
        ).label,
        'Carlsen, Magnus vs Nakamura, Hikaru',
      );
    });

    test('rated unfinished games stay vs, even with Result *', () {
      expect(
        PgnGameEntry(
          headers: {
            'White': 'Alice',
            'Black': 'Bob',
            'Result': '*',
            'WhiteElo': '2100',
          },
          pgnText: '',
        ).label,
        'Alice (2100) vs Bob',
      );
    });

    test('omitted Result is not treated as a course chapter', () {
      expect(
        PgnGameEntry(
          headers: {'White': 'Carlsen', 'Black': 'Nakamura'},
          pgnText: '',
        ).label,
        'Carlsen vs Nakamura',
      );
    });

    test('course chapter — line uses an em dash', () {
      final game = PgnGameEntry(
        headers: {
          'White': 'Quickstarter Guide',
          'Black': 'Colle - 3...c6 #1',
          'Result': '*',
        },
        pgnText: '',
      );
      expect(game.label, 'Quickstarter Guide — Colle - 3...c6 #1');
      expect(game.isCourseStyle, isTrue);
    });

    test(
      'ordinary unfinished player game does not opt into course reading',
      () {
        final game = PgnGameEntry(
          headers: {
            'White': 'Carlsen, Magnus',
            'Black': 'Nakamura, Hikaru',
            'Result': '*',
          },
          pgnText: '',
        );
        expect(game.isCourseStyle, isFalse);
      },
    );

    test('intro chapter with the same White/Black is just the title', () {
      expect(
        PgnGameEntry(
          headers: {
            'White': 'Introduction',
            'Black': 'Introduction',
            'Result': '*',
          },
          pgnText: '',
        ).label,
        'Introduction',
      );
    });
  });
}
