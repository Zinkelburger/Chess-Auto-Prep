import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_edits.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';

void main() {
  Chapter set([String text = tacticsSet]) =>
      parseChapter(name: 'Default', text: text, game: 0);

  ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

  String gameText(Chapter chapter, int index) => chapter.lines[index].text;

  test('an attempt adds the old app\'s headers in its order, before the long '
      'ones, and rewrites that game alone', () {
    final before = set();
    final after = edited(
      recordAttempt(
        before,
        index: 0,
        solved: false,
        seconds: 44.0961,
        now: DateTime(2026, 9, 22, 20, 18, 43),
      ),
    );
    expect(after.games.rewritten, {0});
    final text = gameText(after.chapter, 0);
    expect(
      text,
      contains(
        '[OpponentBestResponse "Nd4"]\n'
        '[ReviewCount "1"]\n'
        '[SuccessCount "0"]\n'
        '[LastReviewed "2026-09-22T20:18:43.000"]\n'
        '[TimeToSolve "44.096"]\n'
        '[FlawTags "opening hasty"]\n',
      ),
    );
    // The moves and the note are the game's own.
    expect(text, endsWith('{Qe2 +9.9 → +0.3, Qxf7# +9.9} 4. Qxf7# *'));
    for (var i = 1; i < before.lines.length; i++) {
      expect(gameText(after.chapter, i), gameText(before, i));
    }
    // The analyzed-games line stays above the first game.
    expect(
      writeChapter(after.chapter),
      startsWith('; ChessAutoPrep-Analyzed-v1:'),
    );
  });

  test('a later attempt counts on from the first, where the headers are', () {
    final once = edited(
      recordAttempt(
        set(),
        index: 1,
        solved: true,
        seconds: 5,
        now: DateTime(2026, 9, 22),
      ),
    ).chapter;
    final twice = edited(
      recordAttempt(
        once,
        index: 1,
        solved: false,
        seconds: 7.5,
        now: DateTime(2026, 9, 23),
      ),
    ).chapter;
    final stats = puzzleOf(twice.lines[1], 1)!.stats;
    expect(stats.reviews, 2);
    expect(stats.successes, 1);
    expect(stats.seconds, 7.5);
    expect(stats.lastReviewed, DateTime(2026, 9, 23));
    expect(RegExp('ReviewCount').allMatches(gameText(twice, 1)).length, 1);
  });

  test('a game with no long headers takes the new ones at the end of its '
      'header', () {
    final after = edited(
      recordAttempt(
        set(),
        index: 3,
        solved: true,
        seconds: 1,
        now: DateTime(2026, 9, 22),
      ),
    ).chapter;
    expect(
      gameText(after, 3),
      startsWith(
        '[Event "Default #4"]\n[Result "*"]\n'
        '[FEN "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1"]\n'
        '[SetUp "1"]\n[ReviewCount "1"]\n[SuccessCount "1"]\n',
      ),
    );
  });

  test('a rating is written, changed and taken away', () {
    final rated = edited(ratePuzzle(set(), index: 0, stars: 4)).chapter;
    expect(puzzleOf(rated.lines[0], 0)!.stats.stars, 4);
    expect(gameText(rated, 0), contains('[StarRating "4"]\n[FlawTags'));
    expect(ratePuzzle(rated, index: 0, stars: 4), isA<ChapterUnchanged>());
    final cleared = edited(ratePuzzle(rated, index: 0, stars: 0)).chapter;
    expect(gameText(cleared, 0), gameText(set(), 0));
  });

  test('a puzzle the set no longer has is refused', () {
    expect(ratePuzzle(set(), index: 9, stars: 3), isA<ChapterEditRefused>());
    expect(
      recordAttempt(
        set(),
        index: -1,
        solved: true,
        seconds: 1,
        now: DateTime(2026),
      ),
      isA<ChapterEditRefused>(),
    );
  });
}
