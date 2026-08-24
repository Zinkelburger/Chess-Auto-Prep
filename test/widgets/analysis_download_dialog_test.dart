import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/widgets/analysis_download_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The download form asks three things — which site, whose account, how much
/// — with one control each. These tests pin that the range survives a flip of
/// the mode toggle (months and games are remembered separately) and that the
/// dialog pops with what the fields actually say.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  AnalysisPlayerInfo? result;

  Future<void> openDialog(
    WidgetTester tester, {
    String? chesscom,
    String? lichess,
    String? platform,
  }) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<AnalysisPlayerInfo>(
                  context: context,
                  builder: (_) => AnalysisDownloadDialog(
                    chesscomUsername: chesscom,
                    lichessUsername: lichess,
                    initialPlatform: platform,
                  ),
                );
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

  testWidgets('one control per question, and no sliders left over', (
    tester,
  ) async {
    await openDialog(tester);

    expect(find.text('Download a player’s games'), findsOneWidget);
    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    expect(find.byType(SegmentedButton<Object?>), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(RadioListTile<String>), findsNothing);
    // Username + amount, nothing else to fill in.
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('an empty username is refused instead of downloading nothing', (
    tester,
  ) async {
    await openDialog(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter a username'), findsOneWidget);
    expect(find.byType(AnalysisDownloadDialog), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('months mode pops a month range for the chosen site', (
    tester,
  ) async {
    await openDialog(tester, lichess: 'penguingm1', platform: 'lichess');

    await tester.enterText(find.byType(TextField).last, '24');
    await tester.pumpAndSettle();
    expect(find.textContaining('the last 24 months'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(result!.platform, 'lichess');
    expect(result!.username, 'penguingm1');
    expect(result!.monthsBack, 24);
  });

  testWidgets('flipping the toggle keeps each mode’s own number', (
    tester,
  ) async {
    await openDialog(tester, chesscom: 'hikaru');

    await tester.enterText(find.byType(TextField).last, '24');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Last N games'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '100'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '250');
    await tester.pumpAndSettle();

    // Back to months: 24 is still there, not overwritten by 250.
    await tester.tap(find.text('Recent months'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '24'), findsOneWidget);

    await tester.tap(find.text('Last N games'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(result!.monthsBack, isNull);
    expect(result!.maxGames, 250);
  });
}
