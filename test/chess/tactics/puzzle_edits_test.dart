import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_edits.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';

void main() {
  Chapter set([String text = tacticsSet]) =>
      parseChapter(name: 'Default', text: text, game: 0);

  ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

  String gameText(Chapter chapter, int index) => chapter.lines[index].text;

  Fen fenOf(Chapter chapter, int index) =>
      puzzleOf(chapter.lines[index], index)!.fen;

  test('an attempt adds the old app\'s headers in its order, before the long '
      'ones, and rewrites that game alone', () {
    final before = set();
    final after = edited(
      recordAttempt(
        before,
        index: 0,
        fen: fenOf(before, 0),
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
        fen: fenOf(set(), 1),
        solved: true,
        seconds: 5,
        now: DateTime(2026, 9, 22),
      ),
    ).chapter;
    final twice = edited(
      recordAttempt(
        once,
        index: 1,
        fen: fenOf(once, 1),
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
        fen: fenOf(set(), 3),
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
    final rated = edited(
      ratePuzzle(set(), index: 0, fen: fenOf(set(), 0), stars: 4),
    ).chapter;
    expect(puzzleOf(rated.lines[0], 0)!.stats.stars, 4);
    expect(gameText(rated, 0), contains('[StarRating "4"]\n[FlawTags'));
    expect(
      ratePuzzle(rated, index: 0, fen: fenOf(rated, 0), stars: 4),
      isA<ChapterUnchanged>(),
    );
    final cleared = edited(
      ratePuzzle(rated, index: 0, fen: fenOf(rated, 0), stars: 0),
    ).chapter;
    expect(gameText(cleared, 0), gameText(set(), 0));
  });

  test('a puzzle the set no longer has is refused', () {
    expect(
      ratePuzzle(set(), index: 9, fen: fenOf(set(), 0), stars: 3),
      isA<ChapterEditRefused>(),
    );
    expect(
      recordAttempt(
        set(),
        index: -1,
        fen: fenOf(set(), 0),
        solved: true,
        seconds: 1,
        now: DateTime(2026),
      ),
      isA<ChapterEditRefused>(),
    );
  });

  test('an attempt or a rating for a puzzle another now holds the place '
      'of is refused', () {
    final before = set();
    final elsewhere = fenOf(before, 0);
    expect(
      recordAttempt(
        before,
        index: 1,
        fen: elsewhere,
        solved: true,
        seconds: 1,
        now: DateTime(2026),
      ),
      isA<ChapterEditRefused>(),
    );
    expect(
      ratePuzzle(before, index: 1, fen: elsewhere, stars: 1),
      isA<ChapterEditRefused>(),
    );
    expect(writeChapter(before), tacticsSet);
    expect(
      edited(
        ratePuzzle(before, index: 1, fen: fenOf(before, 1), stars: 1),
      ).games.rewritten,
      {1},
    );
  });

  group('deleting a puzzle', () {
    test('takes that game out and leaves every other one as it was', () {
      final before = set();
      final after = edited(
        deletePuzzle(before, index: 1, fen: fenOf(before, 1)),
      );
      expect(after.chapter.lines, hasLength(4));
      expect(after.games.order, [0, 2, 3, 4]);
      expect(writeChapter(after.chapter), isNot(contains('Default #2')));
      expect(
        writeChapter(after.chapter),
        tacticsSet.replaceFirst(
          RegExp(r'\[Event "Default #2"\][\s\S]*?\*\n\n'),
          '',
        ),
      );
    });

    test('a list read before the games moved takes out nothing', () {
      final before = set();
      expect(
        deletePuzzle(before, index: 1, fen: fenOf(before, 0)),
        isA<ChapterEditRefused>(),
      );
    });

    test('the board stays on its game, or takes the next when its own '
        'goes', () {
      final showingThird = parseChapter(
        name: 'Default',
        text: tacticsSet,
        game: 2,
      );
      final other = edited(
        deletePuzzle(showingThird, index: 0, fen: fenOf(showingThird, 0)),
      );
      expect(other.chapter.game, 1);
      final own = edited(
        deletePuzzle(showingThird, index: 2, fen: fenOf(showingThird, 2)),
      );
      expect(own.chapter.game, 2);
      expect(puzzleOf(own.chapter.lines[2], 2)!.fen, fenOf(showingThird, 3));
    });
  });
}
