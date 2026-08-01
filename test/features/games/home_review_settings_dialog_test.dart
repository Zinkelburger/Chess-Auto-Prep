/// The review strip's one gear dialog: which games, whether it starts itself,
/// and how hard it works — all in the same place, applied by one button.
library;

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/widgets/home_review_settings_dialog.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/tactics/mining_settings.dart';
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
                  builder: (_) => HomeReviewSettingsDialog(filters: filters),
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

  /// Every case edits the shared depth setting; put it back afterwards.
  void restoreDepth() {
    final before = MiningSettings.instance.depth;
    addTearDown(() => MiningSettings.instance.setDepth(before));
  }

  testWidgets('cores and depth moved in, and Apply saves them', (tester) async {
    SharedPreferences.setMockInitialValues({});
    restoreDepth();
    final before = MiningSettings.instance.depth;

    final closed = await open(tester);
    expect(find.text('Analysis settings'), findsOneWidget);
    expect(find.byKey(const Key('review-cores-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('review-depth-field')),
      '${before + 2}',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(MiningSettings.instance.depth, before + 2);
    expect(closed.single, isNotNull, reason: 'Apply hands the filters back');
  });

  testWidgets('out-of-range depth is clamped, not refused', (tester) async {
    SharedPreferences.setMockInitialValues({});
    restoreDepth();

    await open(tester);
    await tester.enterText(find.byKey(const Key('review-depth-field')), '99');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(MiningSettings.instance.depth, MiningSettings.maxDepth);
    expect(find.text('Analysis settings'), findsNothing, reason: 'it closed');
  });

  testWidgets('Cancel changes nothing, including the numbers', (tester) async {
    SharedPreferences.setMockInitialValues({});
    restoreDepth();
    final before = MiningSettings.instance.depth;

    final closed = await open(tester);
    await tester.enterText(
      find.byKey(const Key('review-depth-field')),
      '${before + 3}',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(MiningSettings.instance.depth, before);
    expect(closed.single, isNull);
  });

  testWidgets('the edited time controls come back on Apply', (tester) async {
    SharedPreferences.setMockInitialValues({});
    restoreDepth();

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
}
