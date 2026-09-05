/// The moments a game card draws: where the game left the book and each of
/// my mistakes, as positions with the move on them and a ply to open.
library;

import 'package:chess_auto_prep/core/app_state.dart' show PgnViewerTab;
import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/game_moments.dart';
import 'package:chess_auto_prep/features/games/services/game_review_summary.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart'
    show MoveClassification;
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:flutter_test/flutter_test.dart';

RecentGame _game({DeviationReport? deviation, GameReviewSummary? summary}) {
  final game = RecentGame(
    record: GameRecord(
      pgn: '',
      headers: const {'White': 'me', 'Black': 'opp', 'Result': '1-0'},
      date: DateTime(2026, 7, 20),
      speed: GameSpeed.blitz,
      dedupKey: 'g1',
    ),
    platform: GamesPlatform.lichess,
    cachePath: '/tmp/lichess_me.pgn',
    myUsername: 'me',
    meWhite: true,
    sans: const ['e4', 'c5', 'c3', 'd5'],
  );
  game
    ..deviation = deviation
    ..deviationComputed = true
    ..summary = summary;
  return game;
}

// After 1. e4 c5 2. c3 d5: White to move.
const _afterFourPlies =
    'rnbqkbnr/pp2pppp/8/2pp4/4P3/2P5/PP1P1PPP/RNBQKBNR w KQkq - 0 3';

void main() {
  group('book moment', () {
    test(
      'draws the position before the deviation with played and book moves',
      () {
        final moments = buildGameMoments(
          _game(
            deviation: const DeviationReport(
              matchedPlies: 4,
              chapterPath: '/r/alapin.pgn',
              chapterName: 'Alapin',
              pathSans: ['e4', 'c5', 'c3', 'd5'],
              playedSan: 'Nf3',
              byMe: true,
              expectedSans: ['exd5'],
            ),
          ),
        );
        expect(moments, hasLength(1));
        final m = moments.single;
        expect(m.fen, _afterFourPlies);
        expect(m.playedUci, 'g1f3');
        expect(m.wantedUcis, ['e4d5']);
        expect(m.byMe, isTrue);
        expect(m.title, '3. Nf3');
        expect(m.detail, 'You left book');
        expect(m.bookEnd, isFalse);
        // Lands after the deviating move, on the line tab.
        expect(m.ply, 5);
        expect(m.tab, PgnViewerTab.line);
        expect(m.tooltip, contains('book plays exd5'));
      },
    );

    test('a book end says so and has no wanted move', () {
      final m = buildGameMoments(
        _game(
          deviation: const DeviationReport(
            matchedPlies: 4,
            chapterPath: '/r/alapin.pgn',
            chapterName: 'Alapin',
            pathSans: ['e4', 'c5', 'c3', 'd5'],
            playedSan: 'exd5',
          ),
        ),
      ).single;
      expect(m.detail, 'Book ends here');
      expect(m.wantedUcis, isEmpty);
      expect(m.playedUci, 'e4d5');
      // Nobody erred here, so the card must not paint the move as a mistake.
      expect(m.bookEnd, isTrue);
    });

    test('their deviation is a moment too, marked as theirs', () {
      final m = buildGameMoments(
        _game(
          deviation: const DeviationReport(
            matchedPlies: 3,
            chapterPath: '/r/alapin.pgn',
            chapterName: 'Alapin',
            pathSans: ['e4', 'c5', 'c3'],
            playedSan: 'd5',
            byMe: false,
            expectedSans: ['Nf6', 'e6'],
          ),
        ),
      ).single;
      expect(m.byMe, isFalse);
      expect(m.detail, 'They left book');
      expect(m.title, '2... d5');
      expect(m.wantedUcis, ['g8f6', 'e7e6']);
    });

    test('a game still in book has no book moment', () {
      expect(
        buildGameMoments(
          _game(
            deviation: const DeviationReport(
              matchedPlies: 4,
              chapterPath: '/r/alapin.pgn',
              chapterName: 'Alapin',
              pathSans: ['e4', 'c5', 'c3', 'd5'],
            ),
          ),
        ),
        isEmpty,
      );
      expect(buildGameMoments(_game()), isEmpty);
    });
  });

  group('mistake moments', () {
    test('carry the classification, eval and engine move', () {
      final m = buildGameMoments(
        _game(
          summary: const GameReviewSummary(
            blunders: 1,
            mistakes: 0,
            inaccuracies: 0,
            moments: [
              ReviewMoment(
                ply: 5,
                san: 'Qh5',
                fenBefore: _afterFourPlies,
                classification: MoveClassification.blunder,
                scoreCp: -180,
                bestSan: 'exd5',
              ),
            ],
          ),
        ),
      ).single;
      expect(m.ply, 5);
      expect(m.tab, PgnViewerTab.analysis);
      expect(m.playedUci, 'd1h5');
      expect(m.wantedUcis, ['e4d5']);
      expect(m.title, '3. Qh5??');
      expect(m.detail, 'Blunder -1.8');
      expect(m.classification, MoveClassification.blunder);
    });

    test('are ordered by ply together with the book moment', () {
      final moments = buildGameMoments(
        _game(
          deviation: const DeviationReport(
            matchedPlies: 4,
            chapterPath: '/r/alapin.pgn',
            chapterName: 'Alapin',
            pathSans: ['e4', 'c5', 'c3', 'd5'],
            playedSan: 'Nf3',
            byMe: true,
            expectedSans: ['exd5'],
          ),
          summary: const GameReviewSummary(
            blunders: 0,
            mistakes: 1,
            inaccuracies: 1,
            moments: [
              ReviewMoment(
                ply: 3,
                san: 'c3',
                fenBefore:
                    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
                classification: MoveClassification.inaccuracy,
              ),
              ReviewMoment(
                ply: 7,
                san: 'Bc4',
                fenBefore: _afterFourPlies,
                classification: MoveClassification.mistake,
              ),
            ],
          ),
        ),
      );
      expect(moments.map((m) => m.ply), [3, 5, 7]);
      expect(moments[0].detail, 'Inaccuracy');
      expect(moments[0].title, '2. c3?!');
    });
  });

  test('the model keeps its moments until the inputs change', () {
    final game = _game(
      summary: const GameReviewSummary(
        blunders: 0,
        mistakes: 0,
        inaccuracies: 1,
        moments: [
          ReviewMoment(
            ply: 1,
            san: 'e4',
            fenBefore:
                'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
            classification: MoveClassification.inaccuracy,
          ),
        ],
      ),
    );
    final first = game.moments;
    expect(identical(first, game.moments), isTrue);
    game.summary = const GameReviewSummary(
      blunders: 0,
      mistakes: 0,
      inaccuracies: 0,
    );
    expect(game.moments, isEmpty);
  });
}
