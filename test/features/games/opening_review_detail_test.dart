/// The opening-review detail dialog: one board, Game / Your book tabs, both
/// opened at the deviation point, book tab showing the repertoire line with
/// its comments.
library;

import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/opening_review.dart';
import 'package:chess_auto_prep/features/games/widgets/opening_review_detail_dialog.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _gamePgn =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/abc123"]\n'
    '[White "me"]\n'
    '[Black "opp"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 c5 2. Nf3 d6 3. d4 Nf6 *';

OpeningReviewEntry _entry() {
  final game = RecentGame(
    record: GameRecord.parse(_gamePgn),
    platform: GamesPlatform.lichess,
    cachePath: '/tmp/lichess_me.pgn',
    myUsername: 'me',
    meWhite: true,
    sans: const ['e4', 'c5', 'Nf3', 'd6', 'd4', 'Nf6'],
  );
  game
    ..deviationComputed = true
    ..bookDesignated = true
    ..deviation = const DeviationReport(
      matchedPlies: 5,
      chapterPath: '/repertoire/Sicilian.pgn',
      chapterName: 'Sicilian',
      pathSans: ['e4', 'c5', 'Nf3', 'd6', 'd4'],
      playedSan: 'Nf6',
      byMe: true,
      expectedSans: ['cxd4'],
    );
  return aggregateOpeningReview([game]).mistakes.single;
}

RepertoireLine _bookLine() {
  return RepertoireLine(
    id: 'open-sicilian-main',
    name: 'Open Sicilian – Main',
    moves: const ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4'],
    color: 'black',
    startPosition: Chess.initial,
    fullPgn:
        '[Event "Sicilian"]\n'
        '[Result "*"]\n'
        '\n'
        '1. e4 c5 2. Nf3 d6 3. d4 cxd4 '
        '{ Recapture with the knight next. } 4. Nxd4 *',
  );
}

Future<void> _pumpDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: OpeningReviewDetailDialog(
          entry: _entry(),
          bookEnd: false,
          onEditInBuilder: () {},
          onOpenGame: (_) {},
          loadLines: (_) async => [_bookLine()],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the deviation header, tabs, and one board', (
    tester,
  ) async {
    await _pumpDialog(tester);

    expect(find.text('Sicilian · move 3'), findsOneWidget);
    expect(
      find.textContaining('You played 3... Nf6 — book plays 3... cxd4'),
      findsOneWidget,
    );
    expect(find.text('Game'), findsOneWidget);
    expect(find.text('Your book'), findsOneWidget);
    expect(find.byType(ChessBoardWidget), findsOneWidget);
    expect(find.text('Edit in Builder'), findsOneWidget);
    expect(find.text('Open game in viewer'), findsOneWidget);
  });

  testWidgets('book tab shows the repertoire line with its comment', (
    tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.text('Your book'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Recapture with the knight next.',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });
}
