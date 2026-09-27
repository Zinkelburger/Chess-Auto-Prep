import 'package:chess_auto_prep/chess_core/pgn/game_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'platform orientations share a game; tournament URLs do not identify one',
    () {
      expect(
        platformGameUrl('https://lichess.org/Ab123456Wxyz/black'),
        'https://lichess.org/Ab123456',
      );
      expect(
        platformGameUrl('https://chess.com/game/live/123456/'),
        'https://www.chess.com/game/live/123456',
      );
      expect(
        platformGameUrl('https://lichess.org/tournament/Ab123456'),
        isNull,
      );
    },
  );
  test(
    'local bookmarks survive annotation changes but distinguish chess content',
    () {
      const headers = {
        'White': 'Reader',
        'Black': 'Opponent',
        'Date': '2026.09.17',
      };
      final original = canonicalGameKey(headers, '1. e4 e5 *');
      expect(
        canonicalGameKey({
          ...headers,
          'StudyRating': '5',
        }, '1. e4 {New note} e5 *'),
        original,
      );
      expect(canonicalGameKey(headers, '1. e4 c5 *'), isNot(original));
      expect(
        canonicalGameKey({...headers, 'Round': '2'}, '1. e4 e5 *'),
        isNot(original),
      );
    },
  );
  test(
    'explicit imported identity wins without conflating distinct source games',
    () {
      expect(canonicalGameKey({'GameId': 'owned'}, '1. e4 *'), 'owned');
      expect(
        canonicalGameKey(
          {'GameId': 'owned', 'Site': 'https://lichess.org/Ab123456'},
          '1. e4 *',
          preferHeaderId: false,
        ),
        'https://lichess.org/Ab123456',
      );
    },
  );
}
