import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pgn_round_trip.dart';

/// Text a file should not hold. Reading must answer, not throw.
const _nonsense = [
  '',
  '   ',
  '{',
  '}',
  '(',
  ')',
  r'$',
  '[',
  '[Event',
  '[Event "',
  '1.',
  '1. e4 ({[( e5 *',
  r'$1 $2 $255',
  '*',
  '1-0',
  'Zz9',
  '1. e4 \u{1F600} *',
];

void main() {
  group('the game termination marker', () {
    test('is read as the file wrote it', () {
      for (final marker in const ['1-0', '0-1', '1/2-1/2', '*']) {
        expect(readGame('1. e4 $marker').terminator, marker, reason: marker);
      }
    });

    test('is not the Result tag, and neither replaces the other', () {
      final read = readGame('[Result "*"]\n\n1. e4 1-0');
      expect(read.terminator, '1-0');
      expect(tagValue(read.tags, 'Result'), '*');
      expectExactRoundTrip('[Result "*"]\n\n1. e4 1-0');
    });

    test('a game with none keeps having none', () {
      final read = readGame('[Event "A"]\n\n1. e4 e5');
      expect(read.terminator, isNull);
      expectExactRoundTrip('[Event "A"]\n\n1. e4 e5');
    });

    test('a game with no Result tag keeps its marker', () {
      expectExactRoundTrip('[Event "A"]\n\n1. e4 1-0');
    });

    test('a second one is reported', () {
      expect(readGame('1. e4 * 1-0').issues.last, isA<ExtraTermination>());
    });

    test('moves after it are reported', () {
      final read = readGame('1. e4 * e5');
      expect(read.issues.single, isA<MovesAfterTermination>());
    });
  });

  group('text nothing can read', () {
    test('an unusable FEN leaves the game unread', () {
      final read = readGame('[FEN "not a fen"]\n\n1. e4 *');
      expect(read.tree, isNull);
      expect(read.issues.single, isA<UnreadablePosition>());
    });

    test('a word that is not a move is reported where it stands', () {
      final read = readGame('[Event "A"]\n\n1. e4 zzz e5 *');
      final issue = read.issues.single;
      expect(issue, isA<UnknownToken>());
      expect(issue.line, 3);
      expect(issue.column, 7);
    });

    test('a percent escape among the moves is reported', () {
      final read = readGame('[Event "A"]\n\n1. e4\n%a directive\ne5 *');
      expect(read.issues.single, isA<EscapeInMovetext>());
    });

    test('a percent escape in the header is a header line', () {
      final read = readGame(
        '[Event "A"]\n%a directive\n[Result "*"]\n\n1. e4 *',
      );
      expect(read.tags.map((t) => t.text), [
        '[Event "A"]',
        '%a directive',
        '[Result "*"]',
      ]);
      expect(read.issues, isEmpty);
    });

    test('nothing throws, whatever the text is', () {
      for (final text in _nonsense) {
        expect(() => readGame(text), returnsNormally, reason: '"$text"');
      }
    });
  });
}
