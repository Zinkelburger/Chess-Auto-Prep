import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

void main() {
  final lines = parseChapter(name: 'games', text: threeGameFile).lines;

  test('a game is named by its players, with its result and setting', () {
    final game = summarizeGame(lines[0], index: 0);
    expect(game.title, 'Carlsen, Magnus – Nakamura, Hikaru');
    expect(game.result, '1-0');
    expect(game.setting, 'Tata Steel · 2024');
  });

  test('a draw reads as halves', () {
    expect(summarizeGame(lines[1], index: 1).result, '½-½');
  });

  test('unknown players, an unknown date and no result are left out', () {
    final game = summarizeGame(lines[2], index: 2);
    expect(game.title, 'Club night');
    expect(game.result, '');
    expect(game.setting, '');
  });

  test('a game with no tags at all is named by its place in the file', () {
    final bare = parseChapter(
      name: 'x',
      text: '[Event "?"]\n\n1. e4 *\n',
    ).lines.single;
    expect(summarizeGame(bare, index: 4).title, 'Game 5');
  });

  test('one known player is the title on their own', () {
    final one = parseChapter(
      name: 'x',
      text: '[Event "Simul"]\n[White "Kasparov"]\n[Black "?"]\n\n1. e4 *\n',
    ).lines.single;
    final game = summarizeGame(one, index: 0);
    expect(game.title, 'Kasparov');
    expect(game.setting, 'Simul');
  });

  test('the search text holds the title, result and setting, lowercased', () {
    expect(
      summarizeGame(lines[0], index: 0).searchText,
      'carlsen, magnus – nakamura, hikaru 1-0 tata steel · 2024',
    );
  });
}
