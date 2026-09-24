import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/v2/app/app.dart';
import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  testWidgets('closing blocks an existing dialog and Stay restores its draft', (
    tester,
  ) async {
    final session = await openSession(blackChapter);
    addTearDown(session.dispose);
    final navigator = GlobalKey<NavigatorState>();
    final field = TextEditingController(text: 'A name being edited');
    addTearDown(field.dispose);
    final pending = Completer<String?>();
    var applied = 0;
    var enginesStopped = false;
    final exit = AppExit(
      navigatorKey: navigator,
      guard: ExitGuard(
        saver: session.saver,
        question: DraftDialog(navigator),
        settleFeatures: () => pending.future,
      ),
      stopEngines: () async => enginesStopped = true,
      closeLog: () async {},
    );
    addTearDown(exit.closing.dispose);
    await _window(tester, navigator);
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (context) => AlertDialog(
          content: TextField(controller: field, autofocus: true),
          actions: [
            TextButton(onPressed: () => applied++, child: const Text('Apply')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final closing = exit.leave();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(applied, 0);
    expect(enginesStopped, isFalse);
    pending.complete('A rating was not saved');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stay here'));
    await tester.pumpAndSettle();
    expect(await closing, AppExitResponse.cancel);
    expect(field.text, 'A name being edited');
    await tester.enterText(find.byType(TextField), 'A revised name');
    await tester.tap(find.text('Apply'));
    expect(applied, 1);
    expect(enginesStopped, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('withdraw removes its prompt, never a newer route', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _window(tester, navigator);
    final question = DraftDialog(navigator);
    final answer = question.put((
      body: 'Unsaved',
      leave: 'Leave',
      offerCopy: false,
    ));
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Newer route')),
      ),
    );
    await tester.pumpAndSettle();
    question.withdraw();
    await tester.pumpAndSettle();
    expect(await answer, isNull);
    expect(find.text('Newer route'), findsOneWidget);
    expect(find.text('Unsaved'), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });
}

Future<void> _window(
  WidgetTester tester,
  GlobalKey<NavigatorState> navigator,
) => tester.pumpWidget(
  MaterialApp(
    navigatorKey: navigator,
    theme: darkTheme(),
    home: const Scaffold(body: Text('Workspace')),
  ),
);
