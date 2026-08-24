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

  testWidgets('the usernames section is a summary and a button', (
    tester,
  ) async {
    await pumpSection(tester, const ChessUsernamesSection());

    expect(find.text('Log into Lichess'), findsNothing);
    expect(find.text('No usernames set'), findsOneWidget);
    expect(find.text('Set up…'), findsOneWidget);
    // The boxes are in the dialog, not on the settings page.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the dialog commits both usernames on Save', (tester) async {
    final appState = await pumpSection(tester, const ChessUsernamesSection());

    await tester.tap(find.text('Set up…'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('lichess-username-field')),
      '  MyLichessName ',
    );
    await tester.enterText(
      find.byKey(const Key('chesscom-username-field')),
      'MyChesscomName',
    );
    // Nothing is saved while typing — Save is the commit.
    expect(appState.lichessUsername, isNull);

    await tester.tap(find.byKey(const Key('accounts-save-button')));
    await tester.pumpAndSettle();

    expect(appState.lichessUsername, 'MyLichessName');
    expect(appState.chesscomUsername, 'MyChesscomName');
    expect(find.text('Lichess: MyLichessName'), findsNothing);
    expect(
      find.textContaining('MyLichessName'),
      findsOneWidget,
      reason: 'the tile now names what was saved',
    );

    // Clearing a box clears the saved default rather than storing ''.
    await tester.tap(find.text('Change…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('lichess-username-field')), '');
    await tester.tap(find.byKey(const Key('accounts-save-button')));
    await tester.pumpAndSettle();
    expect(appState.lichessUsername, isNull);
  });

  testWidgets('Cancel leaves the saved names alone', (tester) async {
    final appState = await pumpSection(tester, const ChessUsernamesSection());

    await tester.tap(find.text('Set up…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('lichess-username-field')),
      'typed-then-abandoned',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(appState.lichessUsername, isNull);
  });

  testWidgets('the tile names what is already configured', (tester) async {
    SharedPreferences.setMockInitialValues({'lichess_username': 'prefilled'});
    final appState = AppState();
    await appState.loadUsernames();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ChessUsernamesSection()),
          ),
        ),
      ),
    );

    expect(find.text('Lichess: prefilled'), findsOneWidget);
    expect(find.text('Change…'), findsOneWidget);
  });
}
