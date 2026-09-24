import 'dart:async';

import 'package:chess_auto_prep/v2/features/library/library_messages.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/ui/error_bar.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/status_host.dart';

void main() {
  testWidgets('a failed change retries after its original row is removed', (
    tester,
  ) async {
    final origin = ValueNotifier(true);
    addTearDown(origin.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: ValueListenableBuilder(
              valueListenable: origin,
              builder: (_, visible, _) => visible
                  ? Builder(
                      builder: (built) {
                        context = built;
                        return const Text('Original row');
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    var calls = 0;
    final held = Completer<LibraryResult>();
    await announce(
      context,
      Future.value(
        LibraryFailure(
          'The saved change needs recovery.',
          retry: () {
            calls++;
            return held.future;
          },
        ),
      ),
      thing: 'chapter',
      name: 'Main',
      failed: 'Could not rename the chapter.',
    );
    origin.value = false;
    await tester.pumpAndSettle();
    expect(context.mounted, isFalse);
    expect(
      find.textContaining('The saved change needs recovery.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('Retry'), findsNothing);
    held.complete(
      LibraryFailure(
        'The destination is still unavailable.',
        retry: () async => const LibraryDone(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The destination is still unavailable.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Change saved.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a Reload that cannot read the chapter again says why', (
    tester,
  ) async {
    final main = ref('benko', 'Main');
    final fixture = await openLibrary([
      folder('benko', ['Main']),
    ], open: main);
    addTearDown(fixture.dispose);
    late BuildContext context;
    final said = ValueNotifier<({String text, StatusAction? action})?>(null);
    addTearDown(said.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusScope(
            say: (text, {action}) => said.value = (text: text, action: action),
            child: ValueListenableBuilder(
              valueListenable: said,
              builder: (built, status, _) {
                context = built;
                return status == null
                    ? const SizedBox.shrink()
                    : ErrorBar(
                        status.text,
                        action: status.action,
                        onClose: () => said.value = null,
                      );
              },
            ),
          ),
        ),
      ),
    );
    unawaited(
      announce(
        context,
        Future.value(const LibraryConflicted()),
        thing: 'chapter',
        name: 'Main',
        failed: 'Could not rename the chapter.',
        reload: fixture.library.reloadOpenChapter,
      ),
    );
    await tester.pumpAndSettle();
    // The file went while the message was up.
    fixture.store.documents.remove(main);

    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();

    expect(find.text('Main is no longer on disk'), findsOneWidget);
  });
}
