import 'dart:async';

import 'package:chess_auto_prep/v2/features/library/library_messages.dart';
import 'package:chess_auto_prep/v2/features/library/library_state.dart';
import 'package:chess_auto_prep/v2/ui/error_bar.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

void main() {
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
