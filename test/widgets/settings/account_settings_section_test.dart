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

  testWidgets('the usernames section carries no login controls', (
    tester,
  ) async {
    await pumpSection(tester, const ChessUsernamesSection());

    expect(find.text('Log into Lichess'), findsNothing);
    expect(find.text('Lichess username'), findsOneWidget);
    expect(find.text('Chess.com username'), findsOneWidget);
  });

  testWidgets('username fields commit to AppState on submit', (tester) async {
    final appState = await pumpSection(tester, const ChessUsernamesSection());

    // Index 0 = Lichess, index 1 = Chess.com.
    await tester.enterText(find.byType(TextField).at(0), '  MyLichessName ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(appState.lichessUsername, 'MyLichessName');

    await tester.enterText(find.byType(TextField).at(1), 'MyChesscomName');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(appState.chesscomUsername, 'MyChesscomName');

    // Clearing a field clears the saved default rather than storing ''.
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(appState.lichessUsername, isNull);
  });

  testWidgets('fields prefill from AppState', (tester) async {
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

    expect(find.text('prefilled'), findsOneWidget);
  });
}
