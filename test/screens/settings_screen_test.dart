/// Settings is a long page of cards. The body must be a bounded ListView —
/// wrapping it in Align first made the list grow to fit every section, the
/// scaffold clipped the overflow, and engine / database / agent-bridge were
/// unreachable.
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/tournament/services/tournament_session.dart';
import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a short window can still scroll to engine and agent bridge', (
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
          ChangeNotifierProvider<TournamentSession>(
            create: (_) => TournamentSession(),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your chess usernames'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Agent bridge (MCP)'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Agent bridge (MCP)'), findsOneWidget);
    expect(find.text('Reset All to Defaults'), findsOneWidget);
  });
}
