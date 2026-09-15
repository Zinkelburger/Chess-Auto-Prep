import 'package:chess_auto_prep/features/tactics/services/tactics_import_pgn_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

const _lichessGame = '''
[Event "Rated Blitz game"]
[Site "https://lichess.org/AbCdEfGh"]
[Date "2024.06.15"]
[White "userA"]
[Black "opp"]
[WhiteElo "1850"]
[BlackElo "1790?"]
[Result "1-0"]

1. e4 e5 2. Nf3 1-0
''';

const _chesscomGame = '''
[Event "Live Chess"]
[Site "Chess.com"]
[UTCDate "2024.05.02"]
[White "opp"]
[Black "userA"]
[Link "https://www.chess.com/game/live/123456789"]

1. d4 d5 *
''';

void main() {
  group('extractGameId', () {
    test('a Lichess Site URL becomes a lichess_ id', () {
      expect(extractGameId(_lichessGame), 'lichess_AbCdEfGh');
    });

    test('a Chess.com Link URL becomes a chesscom_ id', () {
      expect(extractGameId(_chesscomGame), 'chesscom_123456789');
    });

    test('a prefixed GameId header wins over the URL', () {
      final text = _lichessGame.replaceFirst(
        '[Date',
        '[GameId "chesscom_999"]\n[Date',
      );
      expect(extractGameId(text), 'chesscom_999');
    });

    test('a bare GameId header is attributed to Lichess', () {
      const text = '[Event "?"]\n[GameId "xyz"]\n\n1. e4 *\n';
      expect(extractGameId(text), 'lichess_xyz');
    });

    test('a game with no recognizable identity yields an empty id', () {
      const text = '[Event "Club"]\n[Site "Boston"]\n\n1. e4 *\n';
      expect(extractGameId(text), '');
    });
  });

  group('injectGameIdHeader', () {
    test('adds the header just before the movetext, after the blank line', () {
      // The stored copy is what the games store dedups and re-reads, so the
      // placement is pinned: right above the first movetext line.
      expect(
        injectGameIdHeader(_lichessGame),
        _lichessGame.replaceFirst(
          '\n\n1. e4',
          '\n\n[GameId "lichess_AbCdEfGh"]\n1. e4',
        ),
      );
    });

    test('adds the header right after the headers when movetext follows', () {
      const text = '[Site "https://lichess.org/AbCdEfGh"]\n1. e4 *\n';
      expect(
        injectGameIdHeader(text),
        '[Site "https://lichess.org/AbCdEfGh"]\n'
        '[GameId "lichess_AbCdEfGh"]\n'
        '1. e4 *\n',
      );
    });

    test('leaves a game that already has a GameId untouched', () {
      const text = '[GameId "lichess_x"]\n[Site "https://lichess.org/x"]\n\n*';
      expect(injectGameIdHeader(text), text);
    });

    test('leaves a game with no derivable id untouched', () {
      const text = '[Event "Club"]\n\n1. e4 *\n';
      expect(injectGameIdHeader(text), text);
    });
  });

  group('isGameBefore', () {
    test('compares Date at day granularity', () {
      expect(isGameBefore(_lichessGame, DateTime(2024, 6, 16)), isTrue);
      expect(isGameBefore(_lichessGame, DateTime(2024, 6, 15, 23)), isFalse);
    });

    test('reads UTCDate too', () {
      expect(isGameBefore(_chesscomGame, DateTime(2024, 5, 3)), isTrue);
    });

    test('a game without a date passes the filter', () {
      expect(isGameBefore('[Event "?"]\n\n*', DateTime(2030)), isFalse);
    });
  });

  group('extractUserElo', () {
    test('reads the rating of the side matching the username', () {
      expect(extractUserElo(_lichessGame, 'USERA'), 1850);
      expect(extractUserElo(_lichessGame, 'opp'), 1790);
    });

    test('null when the user did not play or the header is missing', () {
      expect(extractUserElo(_lichessGame, 'nobody'), isNull);
      expect(extractUserElo(_chesscomGame, 'userA'), isNull);
    });
  });
}
