import 'package:chess_auto_prep/features/games/widgets/add_games_to_study.dart';
import 'package:chess_auto_prep/widgets/game_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'selection starts at current game, supports a subset and preserves source order',
    (tester) async {
      List<int>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<List<int>>(
                    context: context,
                    builder: (_) => const StudyGameSelectionDialog(
                      labels: ['Game A', 'Game B', 'Game C'],
                      currentIndex: 1,
                    ),
                  );
                },
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(find.text('Continue with 1'), findsOneWidget);
      await tester.tap(find.text('Game C'));
      await tester.pump();
      await tester.tap(find.text('Game A'));
      await tester.pump();
      await tester.tap(find.text('Game B'));
      await tester.pump();
      await tester.tap(find.text('Continue with 2'));
      await tester.pumpAndSettle();
      expect(result, [0, 2]);
    },
  );

  testWidgets(
    'playback is hidden initially but pause remains reachable while playing',
    (tester) async {
      Widget view({bool enabled = false, bool playing = false}) => MaterialApp(
        home: Scaffold(
          body: GameNavBar(
            games: const [],
            currentIndex: 0,
            showPlayback: enabled,
            isAutoPlaying: playing,
          ),
        ),
      );
      await tester.pumpWidget(view());
      expect(find.text('Play'), findsNothing);
      expect(find.byIcon(Icons.star_border), findsNothing);
      expect(find.byTooltip('Reading options'), findsNothing);
      await tester.pumpWidget(view(enabled: true));
      expect(find.text('Play'), findsOneWidget);
      await tester.pumpWidget(view(playing: true));
      expect(find.text('Pause'), findsOneWidget);
    },
  );
}
