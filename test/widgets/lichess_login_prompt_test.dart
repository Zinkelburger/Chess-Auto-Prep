/// The login hand-off has to survive a browser that never opens — a headless
/// remote desktop, a sandboxed session, no registered default. These pin the
/// escape hatch: the exact authorize URL, on the clipboard, one tap away.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/lichess_auth_service.dart';
import 'package:chess_auto_prep/widgets/lichess_login_prompt.dart';

/// Pumps until [finder] matches, or gives up — the OAuth URL only appears
/// once the local callback server has bound its port.
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  testWidgets('the login link can be copied when the browser will not open', (
    tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    // waitForCallback blocks for five minutes; release the bound port even if
    // an expectation fails before Cancel is tapped.
    addTearDown(LichessAuthService.instance.cancelOAuthFlow);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: LichessLoginButton())),
      ),
    );

    // Nothing to copy before a flow exists.
    expect(find.text('Copy login link'), findsNothing);

    await tester.tap(find.text('Open Lichess to log in'));
    await _pumpUntil(tester, find.text('Copy login link'));
    expect(find.text('Copy login link'), findsOneWidget);

    await tester.tap(find.text('Copy login link'));
    await tester.pump();

    expect(clipboard, startsWith('https://lichess.org/oauth'));
    expect(
      clipboard,
      contains('code_challenge'),
      reason: 'the copied link must be the real PKCE authorize URL',
    );
    expect(find.text('Link copied'), findsOneWidget);

    // Cancelling returns the button immediately, and the abandoned flow must
    // not come back later to report a failure the user chose.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Open Lichess to log in'), findsOneWidget);
    expect(find.text('Copy login link'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('Login did not complete'), findsNothing);
  });
}
