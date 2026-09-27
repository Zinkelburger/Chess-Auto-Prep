import 'package:chess_auto_prep/v2/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/v2/features/settings/lichess_login_dialog.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  testWidgets('login opens the browser and returns success only after saving', (
    tester,
  ) async {
    final login = ScriptedLogin(browserOpens: false);
    var saved = false;
    final account = LichessAccountState(
      login: login,
      read: () async => null,
      write: (_) async {
        saved = true;
        return true;
      },
    );
    addTearDown(account.dispose);
    bool? result;
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
    expect(login.logins, 1);
    expect(find.text('Copy link'), findsOneWidget);
    expect(result, isNull);
    login.browserBack(loggedIn());
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(result, isTrue);
  });

  testWidgets('closing cancels the pending browser login', (tester) async {
    final login = ScriptedLogin();
    final account = LichessAccountState(
      login: login,
      read: () async => null,
      write: (_) async => true,
    );
    addTearDown(account.dispose);
    bool? result;
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
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(login.waiting, isFalse);
    expect(result, isFalse);
  });
}
