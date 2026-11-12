import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/source_game.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';

/// The first puzzle of the fixture set, with the game it came from.
const sourceMoves = '1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qe2 Nd4 5. Qd1';

List<Puzzle> _puzzles(String text) =>
    puzzlesOf(parseChapter(name: 'Default', text: text).lines);

void main() {
  final withSource = tacticsSet.replaceFirst(
    '[FlawTags "opening hasty"]',
    '[FlawTags "opening hasty"]\n[SourceMovetext "$sourceMoves"]',
  );

  test('the set\'s own record of the game finds the move the puzzle is '
      'about', () {
    final puzzle = _puzzles(withSource).first;
    final game = puzzleGame(puzzle)!;
    expect(game.sans, hasLength(9));
    expect(game.mistake, 6);
    expect(game.sans[6], 'Qe2');
    expect(game.tag('White'), 'Me');
    expect(game.tag('Result'), '*');
  });

  test('the saved download is preferred, headers and all', () {
    final puzzle = _puzzles(withSource).first;
    const saved =
        '[White "Me"]\n[Black "Rival"]\n[Result "0-1"]\n[WhiteElo "2010"]\n\n'
        '$sourceMoves 0-1';
    final game = puzzleGame(puzzle, saved: saved)!;
    expect(game.text, saved);
    expect(game.tag('Result'), '0-1');
    expect(game.mistake, 6);
  });

  test('the move the puzzle is about is found at the first ply too, and '
      'not past the game\'s last move', () {
    final puzzle = _puzzles(withSource).first;
    final fromIt = puzzleGame(
      puzzle,
      saved: '[SetUp "1"]\n[FEN "${puzzle.fen.value}"]\n\n4. Qe2 *',
    )!;
    expect(fromIt.mistake, 0);
    final upToIt = puzzleGame(
      puzzle,
      saved: '[Result "*"]\n\n1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 *',
    )!;
    expect(upToIt.mistake, isNull);
  });

  test('a study chapter from a game with no names is the first game, and '
      'keeps a finished result', () {
    final puzzle = _puzzles(withSource).first;
    final unnamed = studyDraft(
      puzzle,
      puzzleGame(puzzle, saved: '[Result "0-1"]\n\n$sourceMoves 0-1'),
    );
    expect(unnamed.name, 'Game 1');
    expect(unnamed.result, '0-1');
    final going = studyDraft(
      puzzle,
      puzzleGame(puzzle, saved: '[Result "*"]\n\n$sourceMoves *'),
    );
    expect(going.result, isNull);
  });

  test('a puzzle from no game has none', () {
    expect(puzzleGame(_puzzles(tacticsSet)[3]), isNull);
  });

  test('a study chapter from a puzzle: its game by its players, or the '
      'puzzle alone', () {
    final puzzles = _puzzles(withSource);
    final draft = studyDraft(puzzles.first, puzzleGame(puzzles.first));
    expect(draft.name, 'Me – Rival');
    expect(draft.moves.children.first.san, 'e4');
    final custom = studyDraft(puzzles[3], null);
    expect(custom.name, 'Black to play');
    expect(custom.moves.rootFen, puzzles[3].fen);
    expect(custom.moves.children.first.san, 'd5');
  });
}
