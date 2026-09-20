import 'dart:async';

import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const moment = Duration(milliseconds: 20);

  test('the window closes as soon as the draft is on the file', () async {
    var asked = 0;
    final guard = ExitGuard(
      flush: () async {},
      ask: () async {
        asked++;
        return DraftChoice.closeAnyway;
      },
      wait: moment,
    );
    expect(await guard.mayClose(), isTrue);
    expect(asked, 0, reason: 'there was nothing to ask about');
  });

  test('a save that never lands asks instead of holding the window', () async {
    final stuck = Completer<void>();
    addTearDown(stuck.complete);
    var asked = 0;
    final guard = ExitGuard(
      flush: () => stuck.future,
      ask: () async {
        asked++;
        return DraftChoice.closeAnyway;
      },
      wait: moment,
    );
    expect(await guard.mayClose(), isTrue);
    expect(asked, 1);
  });

  test('waiting again gives the draft the time it needed', () async {
    final lock = Completer<void>();
    var asked = 0;
    final guard = ExitGuard(
      flush: () => lock.future,
      ask: () async {
        asked++;
        // The other copy of the app lets go while the dialog is up.
        lock.complete();
        return DraftChoice.keepWaiting;
      },
      wait: moment,
    );
    expect(await guard.mayClose(), isTrue);
    expect(asked, 1);
  });

  test('a question nobody answered keeps the window open', () async {
    final stuck = Completer<void>();
    addTearDown(stuck.complete);
    final guard = ExitGuard(
      flush: () => stuck.future,
      ask: () async => null,
      wait: moment,
    );
    expect(await guard.mayClose(), isFalse);
  });

  test('a save that fails outright is not taken for a save', () async {
    final guard = ExitGuard(
      flush: () async => throw StateError('the store fell over'),
      ask: () async => null,
      wait: moment,
    );
    expect(await guard.mayClose(), isFalse);
  });

  testWidgets('the dialog says why and offers both ways out', (tester) async {
    Future<DraftChoice?>? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => answer = askAboutUnsavedDraft(context),
            child: const Text('leave'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('leave'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('another copy of Chess Auto Prep'),
      findsOneWidget,
    );
    expect(find.text('Close and lose changes'), findsOneWidget);

    await tester.tap(find.text('Keep waiting'));
    await tester.pumpAndSettle();
    expect(await answer, DraftChoice.keepWaiting);
  });
}
