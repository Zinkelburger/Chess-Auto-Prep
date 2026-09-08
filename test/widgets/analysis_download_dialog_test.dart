import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
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
    Set<GameSpeed>? speeds,
    AnalysisPlayerInfo? player,
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
                    initialSpeeds: speeds,
                    player: player,
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

  /// The dialog scrolls in a 600px-high test window, and the tappable part
  /// of a checkbox row is the box and its label, not the whole column cell.
  Future<void> tapSpeed(WidgetTester tester, GameSpeed speed) async {
    final box = find.descendant(
      of: find.byKey(Key('download-speed-${speed.name}')),
      matching: find.byType(Checkbox),
    );
    await tester.ensureVisible(box);
    await tester.pumpAndSettle();
    await tester.tap(box);
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

  testWidgets('bullet is off by default, and one tap turns it on', (
    tester,
  ) async {
    await openDialog(tester, chesscom: 'hikaru');

    expect(find.text('Which time controls'), findsOneWidget);
    expect(
      find.textContaining('at blitz, rapid, classical or correspondence'),
      findsOneWidget,
    );

    await tapSpeed(tester, GameSpeed.bullet);
    expect(find.textContaining('at bullet, blitz, rapid'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(result!.speeds, contains(GameSpeed.bullet));
    expect(result!.speeds, contains(GameSpeed.classical));
    expect(result!.speeds, isNot(contains(GameSpeed.ultraBullet)));
  });

  testWidgets('the choice is remembered for the next download', (tester) async {
    await openDialog(tester, chesscom: 'hikaru');
    await tapSpeed(tester, GameSpeed.bullet);
    await tapSpeed(tester, GameSpeed.correspondence);
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();
    expect(result!.speeds, {
      GameSpeed.bullet,
      GameSpeed.blitz,
      GameSpeed.rapid,
      GameSpeed.classical,
    });

    await openDialog(tester, chesscom: 'hikaru');
    expect(
      find.textContaining('at bullet, blitz, rapid or classical'),
      findsOneWidget,
    );
  });

  testWidgets('re-downloading a player starts from that player’s filter', (
    tester,
  ) async {
    await openDialog(
      tester,
      lichess: 'penguingm1',
      platform: 'lichess',
      speeds: {GameSpeed.bullet},
    );
    expect(find.textContaining('at bullet.'), findsOneWidget);
  });

  testWidgets('no time controls at all is refused', (tester) async {
    await openDialog(tester, chesscom: 'hikaru');
    for (final speed in defaultDownloadSpeeds) {
      await tapSpeed(tester, speed);
    }

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('pick at least one time control'),
      findsOneWidget,
    );
    expect(find.byType(AnalysisDownloadDialog), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('downloading a saved player again asks only how much and what', (
    tester,
  ) async {
    await openDialog(
      tester,
      player: AnalysisPlayerInfo(
        platform: 'lichess',
        username: 'penguingm1',
        monthsBack: 12,
        speeds: const {GameSpeed.bullet},
        downloadedAt: DateTime.now().subtract(const Duration(days: 30)),
        gameCount: 400,
      ),
    );

    expect(find.text('Download penguingm1 again'), findsOneWidget);
    expect(find.textContaining('From Lichess · last downloaded'), findsOne);
    // No site toggle, no username: just the amount.
    expect(find.byType(SegmentedButton<String>), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(TextField, '12'), findsOneWidget);
    expect(find.textContaining('at bullet.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '3');
    await tapSpeed(tester, GameSpeed.blitz);
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(result!.platform, 'lichess');
    expect(result!.username, 'penguingm1');
    expect(result!.monthsBack, 3);
    expect(result!.speeds, {GameSpeed.bullet, GameSpeed.blitz});
  });

  testWidgets('a merged opponent is downloaded again for every account', (
    tester,
  ) async {
    await openDialog(
      tester,
      player: const AnalysisPlayerInfo(
        platform: 'import',
        username: 'Jane Doe',
        maxGames: 250,
        accounts: [
          PlayerAccount('chesscom', 'jane1'),
          PlayerAccount('lichess', 'jane2'),
        ],
      ),
    );

    expect(find.text('Download Jane Doe again'), findsOneWidget);
    expect(find.textContaining('From jane1, jane2'), findsOneWidget);
    // Game-count mode, because that is how the set was fetched.
    expect(find.widgetWithText(TextField, '250'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();

    expect(result!.accounts.length, 2);
    expect(result!.monthsBack, isNull);
    expect(result!.maxGames, 250);
  });
}
