/// The tactics home's accounts card: one button when nothing is set up, the
/// names and their download dates once something is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/accounts/accounts_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> pumpCard(WidgetTester tester) async {
    final appState = AppState();
    await appState.loadUsernames();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(home: Scaffold(body: AccountsCard())),
      ),
    );
    await tester.pump();
    return appState;
  }

  testWidgets('nothing set up: one button, no boxes', (tester) async {
    await pumpCard(tester);

    expect(find.text('No accounts set'), findsOneWidget);
    expect(find.text('Set up my accounts'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the button opens the form, and Save fills the card in', (
    tester,
  ) async {
    final appState = await pumpCard(tester);

    await tester.tap(find.byKey(const Key('accounts-setup-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('lichess-username-field')),
      'DrNykterstein',
    );
    await tester.tap(find.byKey(const Key('accounts-save-button')));
    await tester.pumpAndSettle();

    expect(appState.lichessUsername, 'DrNykterstein');
    // The card is now a statement under an ACCOUNTS heading, not a form: the
    // name, the site, and the fact that nothing has been downloaded yet.
    expect(find.text('ACCOUNTS'), findsOneWidget);
    expect(find.text('DrNykterstein'), findsOneWidget);
    expect(find.text('Not downloaded yet'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    // A site with no username is not listed at all — an empty row would read
    // as a Chess.com account that has never synced.
    expect(find.text('Chess.com'), findsNothing);
  });

  testWidgets('a configured card offers Change, not a text box', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lichess_username': 'someone',
      'chesscom_username': 'someone-else',
    });
    await pumpCard(tester);

    expect(find.text('someone'), findsOneWidget);
    expect(find.text('someone-else'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byKey(const Key('accounts-change-button')));
    await tester.pumpAndSettle();

    // The form opens on what is already saved.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('lichess-username-field')))
          .controller
          ?.text,
      'someone',
    );
  });
}
