import 'dart:convert';

import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two games, so a reorder has something to reorder.
const _before =
    '[Event "S: One"]\n\n1. e4 *\n\n'
    '[Event "S: Two"]\n\n1. d4 *\n';

const _swapped =
    '[Event "S: Two"]\n\n1. d4 *\n\n'
    '[Event "S: One"]\n\n1. e4 *\n';

String? refusal(String next, List<int> from) => changeOutsideScope(
  previous: utf8.encode(_before),
  next: utf8.encode(next),
  scope: GamesReordered(from),
);

void main() {
  test('the same games in another order go through', () {
    expect(refusal(_swapped, [1, 0]), isNull);
  });

  test('a game left out goes through when the order says so', () {
    expect(refusal('[Event "S: Two"]\n\n1. d4 *\n', [1]), isNull);
  });

  test('a reorder that also rewrote a game is refused', () {
    const edited =
        '[Event "S: Two"]\n\n1. d4 d5 *\n\n'
        '[Event "S: One"]\n\n1. e4 *\n';
    expect(refusal(edited, [1, 0]), contains('game 2 would change'));
  });

  test('a reorder that kept a game twice is refused', () {
    const twice =
        '[Event "S: One"]\n\n1. e4 *\n\n'
        '[Event "S: One"]\n\n1. e4 *\n';
    expect(refusal(twice, [0, 0]), contains('cannot take'));
  });

  test('an order naming a game the file does not have is refused', () {
    expect(refusal(_swapped, [1, 5]), contains('cannot take'));
  });

  test('an order that does not count the games is refused', () {
    expect(refusal(_swapped, [1]), contains('said it was leaving'));
  });

  test('a changed heading is refused', () {
    const headed = '// Colour: White\n$_swapped';
    expect(refusal(headed, [1, 0]), contains('heading would change'));
  });
}
