/// The opening-review aggregation: per-game deviation reports collapsing
/// into one entry per distinct deviation point, mistakes and book ends kept
/// apart, opponent deviations ignored.
library;

import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/opening_review.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/utils/movetext_builder.dart';
import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter_test/flutter_test.dart';

int _gameCounter = 0;

RecentGame _game({
  DeviationReport? deviation,
  bool designated = true,
  String opponent = 'opp',
}) {
  final id = 'game-${_gameCounter++}';
  final game = RecentGame(
    record: GameRecord(
      pgn: '',
      headers: {'White': 'me', 'Black': opponent, 'Result': '1-0'},
      date: DateTime(2026, 7, 20),
      speed: GameSpeed.blitz,
      dedupKey: id,
    ),
    platform: GamesPlatform.lichess,
    cachePath: '/tmp/lichess_me.pgn',
    myUsername: 'me',
    meWhite: true,
    sans: const [],
  );
  game
    ..deviation = deviation
    ..deviationComputed = true
    ..bookDesignated = designated;
  return game;
}

DeviationReport _report({
  required List<String> pathSans,
  String? playedSan,
  bool? byMe,
  List<String> expectedSans = const [],
  String chapter = 'Sicilian',
}) {
  return DeviationReport(
    matchedPlies: pathSans.length,
    chapterPath: '/repertoire/$chapter.pgn',
    chapterName: chapter,
    pathSans: pathSans,
    playedSan: playedSan,
    byMe: byMe,
    expectedSans: expectedSans,
  );
}

void main() {
  test('identical mistakes across games collapse into one counted entry', () {
    final repeated = _report(
      pathSans: ['e4', 'c5', 'Nf3', 'd6'],
      playedSan: 'Bc4',
      byMe: true,
      expectedSans: ['d4'],
    );
    final oneOff = _report(
      pathSans: ['e4', 'e5'],
      playedSan: 'Ke2',
      byMe: true,
      expectedSans: ['Nf3'],
      chapter: 'Open Games',
    );
    final data = aggregateOpeningReview([
      _game(deviation: oneOff),
      _game(deviation: repeated),
      _game(deviation: repeated),
    ]);

    expect(data.mistakes, hasLength(2));
    // Most repeated first.
    expect(data.mistakes.first.playedSan, 'Bc4');
    expect(data.mistakes.first.games, hasLength(2));
    expect(data.mistakes.last.playedSan, 'Ke2');
    expect(data.bookEnds, isEmpty);
  });

  test('check-suffix variants of the same wrong move group together', () {
    final plain = _report(
      pathSans: ['e4', 'e5', 'Nf3', 'Nc6'],
      playedSan: 'Qh5',
      byMe: true,
      expectedSans: ['Bb5'],
    );
    final suffixed = _report(
      pathSans: ['e4', 'e5', 'Nf3', 'Nc6'],
      playedSan: 'Qh5+',
      byMe: true,
      expectedSans: ['Bb5'],
    );
    final data = aggregateOpeningReview([
      _game(deviation: plain),
      _game(deviation: suffixed),
    ]);
    expect(data.mistakes, hasLength(1));
    expect(data.mistakes.single.games, hasLength(2));
  });

  test('different wrong moves from the same position stay separate', () {
    final base = ['e4', 'c5', 'Nf3'];
    final data = aggregateOpeningReview([
      _game(
        deviation: _report(
          pathSans: base,
          playedSan: 'g6',
          byMe: true,
          expectedSans: ['d6'],
        ),
      ),
      _game(
        deviation: _report(
          pathSans: base,
          playedSan: 'a6',
          byMe: true,
          expectedSans: ['d6'],
        ),
      ),
    ]);
    expect(data.mistakes, hasLength(2));
  });

  test('book ends group by position regardless of the continuation', () {
    final line = ['d4', 'd5', 'c4', 'e6'];
    final data = aggregateOpeningReview([
      _game(
        deviation: _report(pathSans: line, playedSan: 'Nc3', byMe: true),
      ),
      _game(
        deviation: _report(pathSans: line, playedSan: 'Nf3', byMe: true),
      ),
    ]);
    expect(data.mistakes, isEmpty);
    expect(data.bookEnds, hasLength(1));
    expect(data.bookEnds.single.games, hasLength(2));
  });

  test('opponent deviations and in-book games are excluded', () {
    final data = aggregateOpeningReview([
      _game(
        deviation: _report(
          pathSans: ['e4', 'c5'],
          playedSan: 'h5',
          byMe: false,
          expectedSans: ['Nf3'],
        ),
      ),
      _game(deviation: _report(pathSans: ['e4', 'c5', 'Nf3'])),
      _game(deviation: null),
    ]);
    expect(data.isEmpty, isTrue);
    expect(data.anyBookDesignated, isTrue);
  });

  test('anyBookDesignated is false only when no game had a book', () {
    final none = aggregateOpeningReview([
      _game(deviation: null, designated: false),
    ]);
    expect(none.anyBookDesignated, isFalse);
  });

  test('equal counts sort by earlier deviation first', () {
    final deep = _report(
      pathSans: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'],
      playedSan: 'Bxc6',
      byMe: true,
      expectedSans: ['Ba4'],
    );
    final shallow = _report(
      pathSans: ['e4', 'e5'],
      playedSan: 'f4',
      byMe: true,
      expectedSans: ['Nf3'],
    );
    final data = aggregateOpeningReview([
      _game(deviation: deep),
      _game(deviation: shallow),
    ]);
    expect(data.mistakes.first.playedSan, 'f4');
  });

  group('matchingBookLines', () {
    RepertoireLine line(
      String name,
      List<String> moves, {
      Position? start,
      bool isModelGame = false,
    }) {
      return RepertoireLine(
        id: name,
        name: name,
        moves: moves,
        color: 'white',
        startPosition: start ?? Chess.initial,
        fullPgn: '',
        isModelGame: isModelGame,
      );
    }

    test('keeps lines through the prefix, longest first, suffix tolerant', () {
      final lines = [
        line('short', ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4']),
        line('long', ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6']),
        line('other opening', ['d4', 'd5']),
      ];
      // Game reached the position via a check-suffixed SAN spelling.
      final matched = matchingBookLines(lines, ['e4', 'c5', 'Nf3', 'd6']);
      expect(matched.map((l) => l.name), ['long', 'short']);
    });

    test('skips custom-start and shorter-than-prefix lines', () {
      final afterE4 = Chess.initial.play(Chess.initial.parseSan('e4')!);
      final lines = [
        line('custom root', ['c5', 'Nf3'], start: afterE4),
        line('too short', ['e4']),
      ];
      expect(matchingBookLines(lines, ['e4', 'c5']), isEmpty);
    });

    test('a variation through the prefix matches, by move not spelling', () {
      final study = RepertoireLine(
        id: 'study',
        name: 'study',
        moves: ['e4', 'e5', 'Nf3'],
        color: 'white',
        startPosition: Chess.initial,
        fullPgn:
            '[Event "S"]\n[Result "*"]\n\n'
            '1. e4 e5 (1... c5 2. Ngf3 d6 3. Bb5+ Bd7) 2. Nf3 *',
      );
      expect(
        matchingBookLines(
          [study],
          ['e4', 'c5', 'Nf3', 'd6', 'Bb5'],
        ).map((l) => l.name),
        ['study'],
      );
      expect(matchingBookLines([study], ['e4', 'c6']), isEmpty);
    });

    test('skips model games — illustration is not your book', () {
      final lines = [
        line('Kasparov – Karpov', [
          'e4',
          'c5',
          'Nf3',
          'd6',
          'd4',
          'cxd4',
        ], isModelGame: true),
        line('your line', ['e4', 'c5', 'Nf3', 'd6', 'Bb5+']),
      ];
      expect(
        matchingBookLines(lines, ['e4', 'c5', 'Nf3', 'd6']).map((l) => l.name),
        ['your line'],
      );
    });
  });

  test('movetext formatting numbers White and Black moves correctly', () {
    expect(formatNumberedSans(['e4', 'c5', 'Nf3']), '1. e4 c5 2. Nf3');
    expect(formatMoveAtPly(4, 'd4'), '3. d4');
    expect(formatMoveAtPly(5, 'cxd4'), '3... cxd4');

    final entry = aggregateOpeningReview([
      _game(
        deviation: _report(
          pathSans: ['e4', 'c5', 'Nf3', 'd6', 'd4'],
          playedSan: 'Nf6',
          byMe: true,
          expectedSans: ['cxd4'],
        ),
      ),
    ]).mistakes.single;
    expect(entry.moveNumber, 3);
    expect(entry.lineDisplay, '1. e4 c5 2. Nf3 d6 3. d4');
    expect(entry.playedDisplay, '3... Nf6');
    expect(entry.expectedDisplay, '3... cxd4');
  });

  group('repeated', () {
    test(
      'lists only points hit by more than one game, most-repeated first',
      () {
        final twice = _report(
          pathSans: ['e4', 'c5', 'c3'],
          playedSan: 'Nf6',
          byMe: true,
          expectedSans: ['d5'],
        );
        final thrice = _report(pathSans: ['e4', 'c5'], playedSan: 'Nf3');
        final once = _report(
          pathSans: ['e4', 'e5'],
          playedSan: 'Bc4',
          byMe: true,
          expectedSans: ['Nf3'],
        );
        final data = aggregateOpeningReview([
          _game(deviation: once),
          _game(deviation: twice),
          _game(deviation: twice),
          _game(deviation: thrice),
          _game(deviation: thrice),
          _game(deviation: thrice),
        ]);
        final repeated = data.repeated();
        expect(repeated.map((e) => e.games.length), [3, 2]);
        expect(repeated.first.isBookEnd, isTrue);
        expect(repeated.last.isBookEnd, isFalse);
        expect(data.repeated(limit: 1), hasLength(1));
      },
    );

    test('is empty when nothing repeats', () {
      final data = aggregateOpeningReview([
        _game(
          deviation: _report(
            pathSans: ['e4', 'e5'],
            playedSan: 'Bc4',
            byMe: true,
            expectedSans: ['Nf3'],
          ),
        ),
      ]);
      expect(data.repeated(), isEmpty);
    });
  });
}
