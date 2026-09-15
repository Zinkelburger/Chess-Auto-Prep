import 'package:chess_auto_prep/features/repertoire/services/pgn_game_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const game =
      '[Event "Main line"]\n[White "Me"]\n[Result "*"]\n\n1. e4 e6 *\n';

  test('pgnHeaderValue reads one header, missing is null', () {
    expect(pgnHeaderValue(game, 'White'), 'Me');
    expect(pgnHeaderValue(game, 'Result'), '*');
    expect(pgnHeaderValue(game, 'Black'), isNull);
  });

  test('headers go straight after the Event line', () {
    expect(
      insertHeadersAfterEvent(game, '[LineID "abc"]'),
      '[Event "Main line"]\n[LineID "abc"]\n[White "Me"]\n[Result "*"]\n\n'
      '1. e4 e6 *\n',
    );
  });

  test('a game without an Event line gets them at the top', () {
    const bare = '[White "Me"]\n\n1. e4 *\n';
    expect(
      insertHeadersAfterEvent(bare, '[A "1"]\n[B "2"]'),
      '[A "1"]\n[B "2"]\n[White "Me"]\n\n1. e4 *\n',
    );
  });

  test('eventHeaderPattern matches only a full Event header line', () {
    expect(eventHeaderPattern.hasMatch(game), isTrue);
    expect(eventHeaderPattern.hasMatch('[EventDate "2026.01.01"]'), isFalse);
  });
}
