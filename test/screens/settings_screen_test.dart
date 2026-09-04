/// Settings is a long page of cards. The body must be a bounded ListView —
/// wrapping it in Align first made the list grow to fit every section, the
/// scaffold clipped the overflow, and engine / database / reset were
/// unreachable.
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a short window can still scroll to the reset button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>(create: (_) => AppState()),
          ChangeNotifierProvider<EvalDatabaseSettings>.value(
            value: EvalDatabaseSettings.instance,
          ),
          // Not loaded: the panel shows "no games yet" without touching disk.
          ChangeNotifierProvider<MasterGamesService>(
            create: (_) => MasterGamesService(),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your chess usernames'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Reset All to Defaults'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('About & open source'), findsOneWidget);
    expect(find.text('Chess Auto Prep on GitHub'), findsOneWidget);
    expect(find.textContaining('Includes Hivemind by aminwoo'), findsOneWidget);
    expect(find.text('Reset All to Defaults'), findsOneWidget);
  });

  testWidgets('the database sections are a pointer, not a panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>(create: (_) => AppState()),
          ChangeNotifierProvider<EvalDatabaseSettings>.value(
            value: EvalDatabaseSettings.instance,
          ),
          ChangeNotifierProvider<MasterGamesService>(
            create: (_) => MasterGamesService(),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Open Databases'),
      240,
      scrollable: find.byType(Scrollable).first,
    );

    // Master games, your games and the two evaluation stores each had a
    // section here and between them filled more of this screen than
    // everything else put together — while still not answering "how much disk
    // is this using", because no section could see the others. They live on
    // the Databases page now. Re-adding one here is the regression this
    // guards: it would be invisible until the two copies disagreed.
    expect(find.textContaining('Years of games'), findsNothing);
    expect(find.textContaining('ChessDB data directory'), findsNothing);
    expect(find.textContaining('games indexed'), findsNothing);
    expect(find.text('Download evaluations…'), findsNothing);
  });
}
