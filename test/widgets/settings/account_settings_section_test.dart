import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/settings/account_settings_section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Logging in and naming your accounts are two separate sections now, so
  /// each test pumps only the one it is about.
  Future<AppState> pumpSection(WidgetTester tester, Widget section) async {
    final appState = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: section)),
        ),
      ),
    );
    return appState;
  }

  testWidgets('logged out: shows status and login button', (tester) async {
    await pumpSection(tester, const LichessLoginSection());

    expect(find.text('Lichess: not logged in'), findsOneWidget);
    expect(find.text('Log into Lichess'), findsOneWidget);
    expect(find.text('Log out'), findsNothing);
  });

  testWidgets('PAT field is hidden until requested', (tester) async {
    await pumpSection(tester, const LichessLoginSection());

    expect(find.text('Personal access token'), findsNothing);

    await tester.tap(find.text('Use a personal access token instead'));
    await tester.pump();

    expect(find.text('Personal access token'), findsOneWidget);
    expect(find.text('Save token'), findsOneWidget);
  });

  testWidgets('usernames are editable inline and saved explicitly', (
    tester,
  ) async {
    final app = await pumpSection(tester, const ChessUsernamesSection());
    addTearDown(app.dispose);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.enterText(
      find.byKey(const Key('lichess-username-field')),
      '  Alice  ',
    );
    await tester.enterText(
      find.byKey(const Key('chesscom-username-field')),
      'Bob',
    );
    expect(app.lichessUsername, isNull);
    await tester.tap(find.byKey(const Key('accounts-save-button')));
    await tester.pumpAndSettle();
    expect(app.lichessUsername, 'Alice');
    expect(app.chesscomUsername, 'Bob');
    expect(find.text('Usernames saved.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('lichess-username-field')), '');
    await tester.pump();
    expect(find.text('Usernames saved.'), findsNothing);
    await tester.tap(find.byKey(const Key('accounts-save-button')));
    await tester.pumpAndSettle();
    expect(app.lichessUsername, isNull);
    expect(tester.takeException(), isNull);
  });
}
