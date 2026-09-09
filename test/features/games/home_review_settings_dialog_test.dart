import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/features/games/widgets/home_review_settings_dialog.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Opens the dialog. The returned list gets the dialog's result appended
  /// when it closes — Apply's [HomeReviewSettingsResult], or null for Cancel.
  Future<List<HomeReviewSettingsResult?>> open(
    WidgetTester tester, {
    GamesListFilters filters = const GamesListFilters(),
    GamesWindow window = const GamesWindow(),
  }) async {
    final closed = <HomeReviewSettingsResult?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => closed.add(
                await showDialog<HomeReviewSettingsResult>(
                  context: context,
                  builder: (_) => HomeReviewSettingsDialog(
                    filters: filters,
                    window: window,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return closed;
  }

  testWidgets('embedded downloads save without closing', (tester) async {
    HomeReviewSettingsResult? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeReviewSettingsDialog(
            filters: const GamesListFilters(),
            window: const GamesWindow(),
            embedded: true,
            onApply: (result) async {
              saved = result;
            },
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('book-check-games-field')),
      '123',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(saved!.window.bookCheckGames, 123);
    expect(find.byType(HomeReviewSettingsDialog), findsOneWidget);
    expect(find.text('Bulk depth'), findsNothing);
  });

  testWidgets('Cancel discards download edits', (tester) async {
    final closed = await open(tester);
    await tester.enterText(
      find.byKey(const Key('book-check-games-field')),
      '123',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed.single, isNull);
  });

  testWidgets('the games window is here, and comes back on Apply', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    final closed = await open(tester);
    // It is the first thing in the dialog: which games, before how hard the
    // engine works on them.
    expect(find.text('Games to analyse'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('window-games-field')), '35');
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(closed.single?.window.games, 35);
    expect(closed.single?.window.isGameCount, isTrue);
  });

  testWidgets('switching to days keeps the game count typed', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final closed = await open(tester);
    await tester.enterText(find.byKey(const Key('window-games-field')), '35');
    await tester.pump();
    await tester.tap(find.byKey(const Key('window-days-field')));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    final window = closed.single?.window;
    expect(window?.isGameCount, isFalse, reason: 'days mode was picked');
    expect(window?.games, 35, reason: 'the other operand is not discarded');
  });

  testWidgets('the edited time controls come back on Apply', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final closed = await open(
      tester,
      filters: const GamesListFilters(speeds: {GameSpeed.blitz}),
    );
    await tester.tap(find.text('Rapid'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(closed.single?.filters.speeds, {GameSpeed.blitz, GameSpeed.rapid});
  });

  testWidgets('startup check is explicit and can be disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final closed = await open(tester);
    expect(
      find.text('Check for new games when the app starts'),
      findsOneWidget,
    );
    final autoStart = find.byKey(const Key('review-auto-start'));
    await tester.ensureVisible(autoStart);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: autoStart, matching: find.byType(Checkbox)),
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(closed.single?.filters.autoRun, isFalse);
  });
}
