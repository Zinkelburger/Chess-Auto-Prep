import 'dart:convert';

import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String game(String name, String moves) => '[Event "$name"]\n\n$moves *\n\n';

  String? outside(String previous, String next, GamesWritten written) =>
      changeOutsideScope(
        previous: utf8.encode(previous),
        next: utf8.encode(next),
        scope: GamesEdited(written),
      );

  group('the chapter heading', () {
    test('may not shrink, even under an edit to the first game', () {
      expect(
        outside(
          '// A long heading\n\n${game('A', '1. e4')}',
          '// A\n\n${game('A', '1. d4')}',
          GamesWritten(rewritten: {0}),
        ),
        'the chapter heading would change but the edit was to game 1',
      );
    });

    test('of a chapter with no games gains only whitespace for its first '
        'game', () {
      expect(
        outside(
          '// Heading',
          '// Heading\r\n\t \n${game('A', '1. e4')}',
          GamesWritten(appended: 1),
        ),
        isNull,
      );
      expect(
        outside(
          '// Heading',
          '// Heading changed\n\n${game('A', '1. e4')}',
          GamesWritten(appended: 1),
        ),
        'the chapter heading would change but the edit only added 1 game at '
        'the end',
      );
    });
  });

  test('a refusal says what the save declared', () {
    final two = game('A', '1. e4') + game('B', '1. d4');
    expect(
      outside(two, game('A', '1. c4') + game('B', '1. d4'), GamesWritten()),
      'game 1 would change but the edit changed no game',
    );
    expect(
      outside(
        two,
        two + game('C', '1. c4') + game('D', '1. f4'),
        GamesWritten(appended: 1),
      ),
      'the file holds 2 games and the save would leave 4 games, but the edit '
      'only added 1 game at the end',
    );
  });
}
