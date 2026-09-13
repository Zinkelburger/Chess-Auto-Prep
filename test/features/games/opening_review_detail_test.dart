/// The review queue delegates game/book reading to the canonical PGN viewer.
library;

import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/opening_review.dart';
import 'package:chess_auto_prep/features/games/widgets/opening_review_dialog.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/common/static_board_thumbnail.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
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

void main() {
  testWidgets('review entry opens its game in the canonical viewer', (
    tester,
  ) async {
    final entry = _entry();
    RecentGame? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => OpeningReviewDialog(
                  data: aggregateOpeningReview(entry.games),
                  windowLabel: 'last 20 games',
                  onEditLine: (_) {},
                  onOpenGame: (game) => opened = game,
                ),
              ),
              child: const Text('Review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    final preview = tester.widget<StaticBoardThumbnail>(
      find.byType(StaticBoardThumbnail),
    );
    // Both arrows originate from the position before the deviation, so the
    // book capture and the played knight move can be compared on one board.
    expect(
      preview.fen.split(' ').first,
      'rnbqkbnr/pp2pppp/3p4/2p5/3PP3/5N2/PPP2PPP/RNBQKB1R',
    );
    expect(preview.flipped, isFalse);
    expect(preview.arrows.map((arrow) => arrow.uci), ['c5d4', 'g8f6']);
    expect(
      preview.arrows.first.color,
      AppColors.success.withValues(alpha: 0.85),
    );
    expect(preview.arrows.last.color, AppColors.danger.withValues(alpha: 0.9));
    await tester.tap(find.byType(StaticBoardThumbnail));
    await tester.pumpAndSettle();
    expect(opened, same(entry.games.first));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(ChessBoardWidget), findsNothing);
  });
}
