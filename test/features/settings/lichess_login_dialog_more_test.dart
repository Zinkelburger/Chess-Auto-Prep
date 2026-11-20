// The Lichess sign-in dialog dismissed without a choice answers "not
// signed in", and a sign-in that failed marks the row as a warning.
import 'package:chess_auto_prep/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/features/settings/lichess_login_dialog.dart';
import 'package:chess_auto_prep/features/settings/setting_controls.dart';
import 'package:chess_auto_prep/net/lichess_login.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  late ScriptedLogin login;
  late LichessAccountState account;
  bool? result;

  Future<void> open(WidgetTester tester, {bool signedIn = false}) async {
    login = ScriptedLogin();
    account = LichessAccountState(
      login: login,
      read: () async => signedIn ? someone() : null,
      write: (_) async => true,
    );
    addTearDown(account.dispose);
    await account.load();
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showLichessLogin(context, account);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('dismissed with Esc, it answers not signed in', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('cancelling reauthorization does not report a fresh login', (
    tester,
  ) async {
    await open(tester, signedIn: true);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(account.status, isA<SignedIn>());
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('a sign-in that failed marks the row', (tester) async {
    await open(tester);
    login.browserBack(const LoginFailed(LoginProblem.tokenRejected));
    await tester.pumpAndSettle();
    expect(account.problem, isNotNull);
    expect(
      tester.widget<SettingRowView>(find.byType(SettingRowView)).row.warn,
      isTrue,
    );
  });
}
