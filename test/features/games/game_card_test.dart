/// A game card: the mistake counts the review fills in, the opening line it
/// reads from the headers, and the moves preview.
library;

import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/game_moments.dart';
import 'package:chess_auto_prep/features/games/services/game_review_summary.dart';
import 'package:chess_auto_prep/features/games/widgets/game_card.dart';
import 'package:chess_auto_prep/features/games/widgets/repertoire_line_panel.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/abc123"]\n'
    '[White "me"]\n'
    '[Black "opp"]\n'
    '[TimeControl "180+2"]\n'
    '[ECO "B22"]\n'
    '[Opening "Sicilian Defense: Alapin Variation"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 c5 2. c3 1-0';

RecentGame _game({
  GameReviewSummary? summary,
  bool? meWhite = true,
  String pgn = _pgn,
  List<String> sans = const ['e4', 'c5', 'c3'],
}) {
  return RecentGame(
    record: GameRecord.parse(pgn),
    platform: GamesPlatform.lichess,
    cachePath: '/tmp/lichess_me.pgn',
    myUsername: 'me',
    meWhite: meWhite,
    sans: sans,
  )..summary = summary;
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 140, child: child)),
    ),
  ),
);

void main() {
  group('MistakeCounts', () {
    testWidgets('shows inaccuracies, mistakes and blunders as three numbers', (
      tester,
    ) async {
      await _pump(
        tester,
        MistakeCounts(
          game: _game(
            summary: const GameReviewSummary(
              blunders: 0,
              mistakes: 1,
              inaccuracies: 3,
            ),
          ),
        ),
      );

      // Order is inaccuracy → mistake → blunder, worst on the right.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('zeroes stay on screen so the columns line up', (tester) async {
      await _pump(
        tester,
        MistakeCounts(
          game: _game(
            summary: const GameReviewSummary(
              blunders: 0,
              mistakes: 0,
              inaccuracies: 0,
            ),
          ),
        ),
      );

      expect(find.text('0'), findsNWidgets(3));
    });

    testWidgets('an unreviewed game says so, and points at the play button', (
      tester,
    ) async {
      await _pump(tester, MistakeCounts(game: _game()));

      expect(find.text('— — —'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('press play'));
    });

    testWidgets('a game where my side is unknown says that instead', (
      tester,
    ) async {
      await _pump(tester, MistakeCounts(game: _game(meWhite: null)));

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('which side you played'));
    });

    testWidgets('reviewed counts open the game analysis when tapped', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        MistakeCounts(
          game: _game(
            summary: const GameReviewSummary(
              blunders: 1,
              mistakes: 0,
              inaccuracies: 0,
            ),
          ),
          onOpen: () => opened++,
        ),
      );

      await tester.tap(find.text('1'));
      expect(opened, 1);
    });
  });

  group('opening identity', () {
    test('ECO and the opening name read straight off the headers', () {
      final game = _game();
      expect(game.ecoCode, 'B22');
      expect(game.openingName, 'Sicilian Defense: Alapin Variation');
      expect(game.openingDisplay, 'B22 · Sicilian Defense: Alapin Variation');
    });

    test('a Chess.com ECOUrl becomes the opening name', () {
      final game = _game(
        pgn:
            '[White "me"]\n'
            '[Black "opp"]\n'
            '[ECOUrl "https://www.chess.com/openings/Kings-Indian-Defense"]\n'
            '\n'
            '1. d4 Nf6 *',
      );
      expect(game.openingName, 'Kings Indian Defense');
      expect(game.ecoCode, isNull, reason: 'no ECO header at all');
      expect(game.openingDisplay, 'Kings Indian Defense');
    });

    test('an opening name in the ECO slot is not mistaken for a code', () {
      final game = _game(
        pgn:
            '[White "me"]\n'
            '[Black "opp"]\n'
            '[ECO "Sicilian Defense"]\n'
            '\n'
            '1. e4 c5 *',
      );
      expect(game.ecoCode, isNull);
    });

    test('nothing is guessed when the headers say nothing', () {
      final game = _game(pgn: '[White "me"]\n[Black "opp"]\n\n1. e4 c5 *');
      expect(game.openingDisplay, isNull);
    });
  });

  group('movesPreview', () {
    test('numbers the opening moves and marks the truncation', () {
      final game = _game(
        sans: const [
          'e4',
          'c5',
          'Nf3',
          'd6',
          'd4',
          'cxd4',
          'Nxd4',
          'Nf6',
          'Nc3',
        ],
      );
      expect(game.movesPreview(plies: 4), '1. e4 c5 2. Nf3 d6 …');
    });

    test('a short game gets no ellipsis', () {
      expect(_game().movesPreview(), '1. e4 c5 2. c3');
    });

    test('a game with no moves previews as nothing', () {
      expect(_game(sans: const []).movesPreview(), isEmpty);
    });
  });

  group('detectMySide', () {
    const headers = {'White': 'MaouTanner', 'Black': 'someoneElse'};

    test('matches either colour, case-insensitively', () {
      expect(
        detectMySide(headers: headers, myUsernames: const ['maoutanner']),
        isTrue,
      );
      expect(
        detectMySide(headers: headers, myUsernames: const ['SOMEONEELSE']),
        isFalse,
      );
    });

    test('null when neither player is me, or no username is configured', () {
      expect(
        detectMySide(headers: headers, myUsernames: const ['nobody']),
        isNull,
      );
      expect(detectMySide(headers: headers, myUsernames: const []), isNull);
      expect(
        detectMySide(headers: headers, myUsernames: const [null, '  ']),
        isNull,
      );
    });
  });

  group('moments strip', () {
    const leftBook = DeviationReport(
      matchedPlies: 3,
      chapterPath: '/r/alapin.pgn',
      chapterName: 'Alapin',
      pathSans: ['e4', 'c5', 'c3'],
      playedSan: 'd5',
      byMe: false,
      expectedSans: ['Nf6'],
    );

    Future<void> pumpCard(
      WidgetTester tester,
      RecentGame game, {
      required double width,
      void Function(GameMoment)? onOpenMoment,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: GameCard(
                game: game,
                onOpen: () {},
                onOpenAnalysis: () {},
                onOpenLine: () {},
                onOpenMoment: onOpenMoment ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('a wide card shows the moments and opens one on tap', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final game = _game(sans: const ['e4', 'c5', 'c3', 'd5'])
        ..deviation = leftBook
        ..deviationComputed = true;
      GameMoment? opened;
      await pumpCard(tester, game, width: 900, onOpenMoment: (m) => opened = m);

      expect(find.byType(MomentsStrip), findsOneWidget);
      expect(find.text('2... d5'), findsOneWidget);
      expect(find.text('They left book'), findsOneWidget);
      // The text column keeps what it had.
      expect(find.text('Left book at move 2 (them)'), findsOneWidget);

      await tester.tap(find.text('2... d5'));
      expect(opened?.ply, 4);
    });

    testWidgets('a narrow card has no strip and the text keeps the width', (
      tester,
    ) async {
      final game = _game(sans: const ['e4', 'c5', 'c3', 'd5'])
        ..deviation = leftBook
        ..deviationComputed = true;
      await pumpCard(tester, game, width: 520);
      expect(find.byType(MomentsStrip), findsNothing);
      expect(find.text('Left book at move 2 (them)'), findsOneWidget);
    });

    testWidgets('no moments, no strip', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpCard(tester, _game(), width: 900);
      expect(find.byType(MomentsStrip), findsNothing);
    });

    test('stripFits needs the board, the text column and one moment', () {
      expect(GameCard.stripFits(500), isFalse);
      expect(GameCard.stripFits(600), isTrue);
    });
  });
}
