// Get games: the dialog opens on the range kept on the person, answers the
// range chosen, and refuses to run with no time control.
import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/download_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlayerDownloadRange? answer;
  var answered = false;

  Future<void> open(WidgetTester tester, Player player) async {
    answer = null;
    answered = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await downloadRange(context, player);
                answered = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool chipOn(WidgetTester tester, String label) => tester
      .widget<FilterChip>(find.widgetWithText(FilterChip, label))
      .selected;

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Get games'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the range kept on the person and answers it', (
    tester,
  ) async {
    final player = Player.create('Alex').edited({
      'lichess': 'alex',
      'download': {
        'max': 200,
        'months': 3,
        'speeds': ['blitz'],
      },
    });
    await open(tester, player);
    expect(find.text('Get Alex’s games'), findsOneWidget);
    expect(find.text('Lichess alex'), findsOneWidget);
    expect(find.text('Months'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(chipOn(tester, 'Blitz'), isTrue);
    expect(chipOn(tester, 'Rapid'), isFalse);
    await tester.tap(find.byTooltip('Increase Months'));
    await tester.pump();
    await confirm(tester);
    expect(answered, isTrue);
    expect(answer!.months, 4);
    expect(answer!.max, 200);
    expect(answer!.speeds, {'blitz'});
  });

  testWidgets('a count of games is answered with no months, and the time '
      'controls chosen', (tester) async {
    await open(tester, Player.create('Alex').edited({'chesscom': 'alex'}));
    expect(find.text('Games per account'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(chipOn(tester, 'Bullet'), isFalse);
    await tester.tap(find.text('Bullet'));
    await tester.pump();
    await tester.tap(find.text('Classical'));
    await tester.pump();
    await tester.tap(find.byTooltip('Increase Games per account'));
    await tester.pump();
    await confirm(tester);
    expect(answer!.months, isNull);
    expect(answer!.max, 600);
    expect(answer!.speeds, {'bullet', 'blitz', 'rapid', 'correspondence'});
  });

  testWidgets('switched to months, answers six of them by default', (
    tester,
  ) async {
    await open(tester, Player.create('Alex').edited({'lichess': 'alex'}));
    await tester.tap(find.text('Recent months'));
    await tester.pump();
    expect(find.text('6'), findsOneWidget);
    await confirm(tester);
    expect(answer!.months, 6);
    expect(answer!.max, 500);
  });

  testWidgets('with no time control chosen, says so and does not run', (
    tester,
  ) async {
    await open(
      tester,
      Player.create('Alex').edited({
        'lichess': 'alex',
        'download': {
          'speeds': ['rapid'],
        },
      }),
    );
    expect(find.text('Choose at least one time control.'), findsNothing);
    await tester.tap(find.text('Rapid'));
    await tester.pump();
    expect(find.text('Choose at least one time control.'), findsOneWidget);
    await confirm(tester);
    expect(answered, isFalse);
    await tester.tap(find.text('Blitz'));
    await tester.pump();
    await confirm(tester);
    expect(answer!.speeds, {'blitz'});
  });
}
